classdef SMACSurrogate < handle
    %SMACSURROGATE  Gaussian Process surrogate with an acquisition function.
    %
    %   Follows the SMAC idea (Sequential Model-based Algorithm
    %   Configuration): fit a cheap statistical model on the expensive
    %   evaluations done so far, then use it to decide which new candidates
    %   deserve a real evaluation. SMAC itself uses a random forest; here
    %   the model is a Gaussian Process (fitrgp, Matern 5/2 kernel) which
    %   gives a predictive mean mu(x) and standard deviation sigma(x).
    %
    %   Inputs are scaled to [0,1]^D before fitting so the kernel
    %   length scale is not distorted by the size of the field.
    %
    %   Acquisition functions (minimisation; a higher score is better):
    %       EI   Expected Improvement, with f_best the best fitness seen:
    %              z  = (f_best - mu - xi) / sigma
    %              EI = (f_best - mu - xi) * Phi(z) + sigma * phi(z)
    %       LCB  Lower Confidence Bound, score = -(mu - kappa * sigma)
    %   EI balances exploitation (low mu) and exploration (high sigma).
    %
    %   Typical use:
    %       sur = optimizer.SMACSurrogate(env.lowerBounds(), env.upperBounds());
    %       sur.addObservations(X, y);                     % refits when ready
    %       [idx, info] = sur.screen(candidates, 5);       % pick the best 5
    %       rmse = sur.validationRMSE(X_new, y_new);       % out-of-sample error
    %
    %   Requires the Statistics and Machine Learning Toolbox (fitrgp).

    properties (SetAccess = immutable)
        LowerBound          % 1 x D lower limits
        UpperBound          % 1 x D upper limits
        Dimension           % D
        MaxTrainingSize     % cap on stored observations (GP cost grows as n^3)
        MinTrainingSize     % observations needed before the first fit
        EliteFraction       % share of the cap reserved for the best observations
        AcquisitionType     % 'EI' or 'LCB'
        ExplorationMargin   % xi in EI: required improvement margin
        ConfidenceWeight    % kappa in LCB: how much to reward uncertainty
    end

    properties (SetAccess = private)
        TrainInputs         % n x D observed positions, scaled to [0,1]
        TrainTargets        % n x 1 observed fitness values
        BestObserved = Inf  % lowest fitness ever added (survives trimming)
        Model               % fitted RegressionGP object
        NumFits = 0         % how many times the GP was refitted
        TargetMean = 0      % fitness mean used to standardise GP targets
        TargetScale = 1     % fitness std used to standardise GP targets
    end

    methods
        function obj = SMACSurrogate(lower_bound, upper_bound, options)
            arguments
                lower_bound (1,:) double
                upper_bound (1,:) double
                options.MaxTrainingSize (1,1) double {mustBeInteger, mustBePositive} = 300
                options.MinTrainingSize (1,1) double {mustBeInteger, mustBePositive} = 20
                options.EliteFraction (1,1) double {mustBeNonnegative} = 0.2
                options.Acquisition (1,1) string = "EI"
                options.ExplorationMargin (1,1) double {mustBeNonnegative} = 0
                options.ConfidenceWeight (1,1) double {mustBeNonnegative} = 2
            end
            assert(numel(lower_bound) == numel(upper_bound) && all(upper_bound > lower_bound), ...
                'SMACSurrogate:badBounds', 'Bounds must have equal length with upper > lower.');
            assert(options.MinTrainingSize <= options.MaxTrainingSize, 'SMACSurrogate:badSizes', ...
                'MinTrainingSize cannot exceed MaxTrainingSize.');
            assert(options.EliteFraction < 1, 'SMACSurrogate:badElite', ...
                'EliteFraction must be below 1.');

            obj.LowerBound = lower_bound;
            obj.UpperBound = upper_bound;
            obj.Dimension = numel(lower_bound);
            obj.MaxTrainingSize = options.MaxTrainingSize;
            obj.MinTrainingSize = options.MinTrainingSize;
            obj.EliteFraction = options.EliteFraction;
            obj.AcquisitionType = validatestring(options.Acquisition, {'EI', 'LCB'});
            obj.ExplorationMargin = options.ExplorationMargin;
            obj.ConfidenceWeight = options.ConfidenceWeight;

            obj.TrainInputs = zeros(0, obj.Dimension);
            obj.TrainTargets = zeros(0, 1);
        end

        function tf = isReady(obj)
            %ISREADY  True once enough data has been seen to trust a fit.
            tf = numel(obj.TrainTargets) >= obj.MinTrainingSize && ~isempty(obj.Model);
        end

        function addObservations(obj, positions, fitness)
            %ADDOBSERVATIONS  Store real evaluations and refit the GP.
            fitness = fitness(:);
            assert(size(positions, 2) == obj.Dimension && size(positions, 1) == numel(fitness), ...
                'SMACSurrogate:badInput', 'Expected n x %d positions and n fitness values.', obj.Dimension);

            obj.TrainInputs = [obj.TrainInputs; obj.scaleInputs(positions)];
            obj.TrainTargets = [obj.TrainTargets; fitness];
            obj.BestObserved = min(obj.BestObserved, min(fitness));  % record before any trimming

            obj.trimTrainingSet();
            if numel(obj.TrainTargets) >= obj.MinTrainingSize
                obj.fit();
            end
        end

        function [mu, sigma] = predictFitness(obj, positions)
            %PREDICTFITNESS  GP predictive mean and standard deviation.
            assert(obj.isReady(), 'SMACSurrogate:notReady', ...
                'Surrogate needs at least %d observations before predicting.', obj.MinTrainingSize);
            [mu_std, sigma_std] = predict(obj.Model, obj.scaleInputs(positions));
            mu = obj.TargetMean + obj.TargetScale * mu_std;     % back to fitness units
            sigma = max(obj.TargetScale * sigma_std, eps);      % avoid division by zero in EI
        end

        function score = acquisitionScore(obj, mu, sigma)
            %ACQUISITIONSCORE  Desirability of evaluating a point (higher = better).
            if strcmp(obj.AcquisitionType, 'EI')
                improvement = obj.BestObserved - mu - obj.ExplorationMargin;
                z = improvement ./ sigma;
                cdf_z = 0.5 * erfc(-z / sqrt(2));          % standard normal CDF
                pdf_z = exp(-0.5 * z.^2) / sqrt(2 * pi);   % standard normal PDF
                score = improvement .* cdf_z + sigma .* pdf_z;
            else
                score = -(mu - obj.ConfidenceWeight * sigma);
            end
        end

        function [selected_idx, info] = screen(obj, candidates, num_select)
            %SCREEN  Rank candidate positions and return the most promising.
            %   selected_idx are row indices into candidates, best first.
            %   info holds mu, sigma and score for every candidate so the
            %   caller can reuse the predictions for the ones not selected.
            assert(num_select >= 1 && num_select <= size(candidates, 1), ...
                'SMACSurrogate:badSelect', 'num_select must be between 1 and the number of candidates.');

            [mu, sigma] = obj.predictFitness(candidates);
            score = obj.acquisitionScore(mu, sigma);
            [~, order] = sort(score, 'descend');
            selected_idx = order(1:num_select);

            info = struct('mu', mu, 'sigma', sigma, 'score', score);
        end

        function rmse = validationRMSE(obj, positions, fitness)
            %VALIDATIONRMSE  Out-of-sample surrogate error.
            %   Call it on freshly evaluated points BEFORE adding them with
            %   addObservations, so the model has never seen them.
            if ~obj.isReady()
                rmse = NaN;
                return;
            end
            mu = obj.predictFitness(positions);
            rmse = sqrt(mean((mu - fitness(:)).^2));
        end
    end

    methods (Access = private)
        function fit(obj)
            %FIT  Fit the GP; kernel hyper-parameters and noise by marginal likelihood.
            %   Targets are z-scored so the noise floor is relative to the
            %   fitness spread. Smooth noise-free data can still make the
            %   kernel matrix singular, so the fit is retried with a larger
            %   noise floor if the Cholesky factorisation fails.
            obj.TargetMean = mean(obj.TrainTargets);
            obj.TargetScale = std(obj.TrainTargets);
            if ~(obj.TargetScale > 0)
                obj.TargetScale = 1;            % all targets equal: avoid dividing by 0
            end
            targets_std = (obj.TrainTargets - obj.TargetMean) / obj.TargetScale;

            noise_floors = [1e-3 1e-2 1e-1];
            for k = 1:numel(noise_floors)
                try
                    obj.Model = fitrgp(obj.TrainInputs, targets_std, ...
                        'KernelFunction', 'matern52', ...
                        'BasisFunction', 'constant', ...
                        'Standardize', false, ...       % inputs are already scaled to [0,1]
                        'Sigma', max(0.1, 2 * noise_floors(k)), ...
                        'SigmaLowerBound', noise_floors(k));
                    break;
                catch err
                    if k == numel(noise_floors)
                        rethrow(err);
                    end
                end
            end
            obj.NumFits = obj.NumFits + 1;
        end

        function scaled = scaleInputs(obj, positions)
            scaled = (positions - obj.LowerBound) ./ (obj.UpperBound - obj.LowerBound);
        end

        function trimTrainingSet(obj)
            %TRIMTRAININGSET  Keep the best (elite) plus the most recent points.
            %   Elites keep the model accurate near the optimum; recent points
            %   keep it accurate where the pack is searching now.
            num_stored = numel(obj.TrainTargets);
            if num_stored <= obj.MaxTrainingSize
                return;
            end

            elite_count = ceil(obj.EliteFraction * obj.MaxTrainingSize);
            recent_count = obj.MaxTrainingSize - elite_count;

            [~, order] = sort(obj.TrainTargets, 'ascend');
            elite_idx = order(1:elite_count);
            others = setdiff((1:num_stored)', elite_idx, 'stable');
            recent_idx = others(end - recent_count + 1:end);

            keep = sort([elite_idx(:); recent_idx(:)]);
            obj.TrainInputs = obj.TrainInputs(keep, :);
            obj.TrainTargets = obj.TrainTargets(keep);
        end
    end
end

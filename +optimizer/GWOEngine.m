classdef GWOEngine < handle
    %GWOENGINE  Grey Wolf Optimizer (Mirjalili et al., 2014) for minimisation.
    %
    %   The pack hunts around its three best wolves:
    %       alpha (best), beta (second), delta (third). The rest (omegas)
    %   follow them. For every wolf X and every leader X_L:
    %
    %       A   = 2*a*r1 - a            r1, r2 ~ U(0,1) per coordinate
    %       C   = 2*r2
    %       D   = | C .* X_L - X |       distance to the leader
    %       X_k = X_L - A .* D          position suggested by that leader
    %
    %       X_new = (X_alpha' + X_beta' + X_delta') / 3
    %
    %   The control parameter a falls linearly from 2 to 0, so |A| > 1
    %   early on (wolves spread out, explore) and |A| < 1 later (wolves
    %   close in on the prey, exploit).
    %
    %   The engine is split into small steps so a surrogate can sit between
    %   them in a later commit:
    %       initializePack()           -> random starting positions
    %       proposeCandidates()        -> next positions, nothing evaluated
    %       receiveFitness(pos, fit)   -> accept positions, update leaders
    %   run(objective_fn) chains these into the plain GWO loop and serves
    %   as the baseline for comparisons.
    %
    %   Leaders are elitist: alpha/beta/delta are the best positions seen
    %   so far, so the best fitness never gets worse.

    properties (SetAccess = immutable)
        NumWolves               % pack size
        MaxIterations           % number of position updates
        LowerBound              % 1 x D lower limits
        UpperBound              % 1 x D upper limits
        Dimension               % D, number of decision variables
        ControlParameterStart   % initial value of a (2 in the original paper)
    end

    properties (SetAccess = private)
        Iteration = 0           % number of proposeCandidates() calls so far
        WolfPositions           % NumWolves x D current pack
        WolfFitness             % NumWolves x 1 fitness of current pack

        AlphaPosition           % 1 x D best position found
        AlphaFitness = Inf
        BetaPosition            % 1 x D second best
        BetaFitness = Inf
        DeltaPosition           % 1 x D third best
        DeltaFitness = Inf

        NumEvaluations = 0      % total objective evaluations received
        BestFitnessHistory      % alpha fitness after each receiveFitness()
        DiversityHistory        % search diversity after each receiveFitness()
        HistoryCount = 0
    end

    methods
        function obj = GWOEngine(lower_bound, upper_bound, options)
            arguments
                lower_bound (1,:) double
                upper_bound (1,:) double
                options.NumWolves (1,1) double {mustBeInteger, mustBePositive} = 30
                options.MaxIterations (1,1) double {mustBeInteger, mustBePositive} = 100
                options.ControlParameterStart (1,1) double {mustBePositive} = 2
            end
            assert(numel(lower_bound) == numel(upper_bound) && all(upper_bound > lower_bound), ...
                'GWOEngine:badBounds', 'Bounds must have equal length with upper > lower.');
            assert(options.NumWolves >= 4, 'GWOEngine:smallPack', ...
                'Need at least 4 wolves (3 leaders plus one follower).');

            obj.NumWolves = options.NumWolves;
            obj.MaxIterations = options.MaxIterations;
            obj.LowerBound = lower_bound;
            obj.UpperBound = upper_bound;
            obj.Dimension = numel(lower_bound);
            obj.ControlParameterStart = options.ControlParameterStart;

            % Placeholder leaders: infinite fitness means any real wolf replaces them.
            obj.AlphaPosition = nan(1, obj.Dimension);
            obj.BetaPosition = nan(1, obj.Dimension);
            obj.DeltaPosition = nan(1, obj.Dimension);

            obj.BestFitnessHistory = nan(options.MaxIterations + 1, 1);
            obj.DiversityHistory = nan(options.MaxIterations + 1, 1);
        end

        function positions = initializePack(obj)
            %INITIALIZEPACK  Scatter the wolves uniformly over the search space.
            span = obj.UpperBound - obj.LowerBound;
            positions = obj.LowerBound + rand(obj.NumWolves, obj.Dimension) .* span;
        end

        function a = controlParameter(obj)
            %CONTROLPARAMETER  Linear decay of a from its start value to 0.
            progress = obj.Iteration / obj.MaxIterations;
            a = obj.ControlParameterStart * max(1 - progress, 0);
        end

        function candidates = proposeCandidates(obj)
            %PROPOSECANDIDATES  Encircling + hunting update for the whole pack.
            %   Returns the next positions without evaluating them. Fully
            %   vectorised over wolves and dimensions.
            assert(isfinite(obj.AlphaFitness), 'GWOEngine:noLeaders', ...
                'Call receiveFitness() on the initial pack before proposing.');

            a = obj.controlParameter();
            leader_positions = [obj.AlphaPosition; obj.BetaPosition; obj.DeltaPosition];
            num_leaders = size(leader_positions, 1);
            size_pack = [obj.NumWolves, obj.Dimension];

            suggested_sum = zeros(size_pack);
            for k = 1:num_leaders
                leader_pos = leader_positions(k, :);
                A = 2 * a * rand(size_pack) - a;                          % |A|>1 explore, |A|<1 exploit
                C = 2 * rand(size_pack);                                  % random emphasis on the leader
                distance_to_leader = abs(C .* leader_pos - obj.WolfPositions);
                suggested_sum = suggested_sum + (leader_pos - A .* distance_to_leader);
            end

            % Average the three suggestions, then keep wolves inside the search space.
            candidates = suggested_sum / num_leaders;
            candidates = min(max(candidates, obj.LowerBound), obj.UpperBound);

            obj.Iteration = obj.Iteration + 1;
        end

        function receiveFitness(obj, positions, fitness)
            %RECEIVEFITNESS  Accept an evaluated pack and refresh the leaders.
            fitness = fitness(:);
            assert(isequal(size(positions), [obj.NumWolves, obj.Dimension]) && ...
                   numel(fitness) == obj.NumWolves, 'GWOEngine:badInput', ...
                   'Expected %d x %d positions and %d fitness values.', ...
                   obj.NumWolves, obj.Dimension, obj.NumWolves);

            obj.WolfPositions = positions;
            obj.WolfFitness = fitness;
            obj.NumEvaluations = obj.NumEvaluations + obj.NumWolves;
            obj.updateLeaders();

            obj.HistoryCount = obj.HistoryCount + 1;
            obj.BestFitnessHistory(obj.HistoryCount) = obj.AlphaFitness;
            obj.DiversityHistory(obj.HistoryCount) = obj.diversityIndex();
        end

        function diversity = diversityIndex(obj)
            %DIVERSITYINDEX  Mean wolf distance to the pack centroid, scaled
            %   by the search-space diagonal. About 0.3 for a random pack,
            %   near 0 once the pack has collapsed on one spot.
            centroid = mean(obj.WolfPositions, 1);
            distance_to_centroid = sqrt(sum((obj.WolfPositions - centroid).^2, 2));
            diversity = mean(distance_to_centroid) / norm(obj.UpperBound - obj.LowerBound);
        end

        function result = run(obj, objective_fn)
            %RUN  Plain GWO loop. objective_fn maps an (n x D) matrix of
            %   positions to an (n x 1) vector of fitness values.
            positions = obj.initializePack();
            obj.receiveFitness(positions, objective_fn(positions));

            for iter = 1:obj.MaxIterations
                candidates = obj.proposeCandidates();
                obj.receiveFitness(candidates, objective_fn(candidates));
            end
            result = obj.getResult();
        end

        function result = getResult(obj)
            result = struct( ...
                'best_position',   obj.AlphaPosition, ...
                'best_fitness',    obj.AlphaFitness, ...
                'history',         obj.BestFitnessHistory(1:obj.HistoryCount), ...
                'diversity',       obj.DiversityHistory(1:obj.HistoryCount), ...
                'num_evaluations', obj.NumEvaluations);
        end
    end

    methods (Access = private)
        function updateLeaders(obj)
            %UPDATELEADERS  Pick alpha/beta/delta from old leaders + current pack.
            %   Pooling the old leaders with the new pack is what makes the
            %   leaders elitist (a good position is never forgotten).
            pool_positions = [obj.AlphaPosition; obj.BetaPosition; obj.DeltaPosition; obj.WolfPositions];
            pool_fitness = [obj.AlphaFitness; obj.BetaFitness; obj.DeltaFitness; obj.WolfFitness];

            [~, order] = sort(pool_fitness, 'ascend');
            best_three = order(1:3);

            obj.AlphaPosition = pool_positions(best_three(1), :);
            obj.AlphaFitness = pool_fitness(best_three(1));
            obj.BetaPosition = pool_positions(best_three(2), :);
            obj.BetaFitness = pool_fitness(best_three(2));
            obj.DeltaPosition = pool_positions(best_three(3), :);
            obj.DeltaFitness = pool_fitness(best_three(3));
        end
    end
end

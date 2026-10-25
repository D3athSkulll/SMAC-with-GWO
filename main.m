function results = main(options)
%MAIN  Hybrid SMAC-GWO optimisation of a wireless sensor network layout.
%
%   results = main() runs the hybrid optimiser and a plain GWO baseline
%   on the same network problem and returns both runs.
%
%   Each hybrid iteration works like this:
%     1. GWO proposes NumProposals candidate moves for every wolf
%        (encircling/hunting equations, nothing evaluated yet).
%     2. The SMAC surrogate (GP + Expected Improvement) scores every
%        candidate; each wolf keeps its highest-scoring proposal.
%     3. Only the EvalFraction most promising wolves are sent to the
%        expensive network simulation. The others move using the GP's
%        predicted fitness, but cannot become alpha/beta/delta.
%     4. The surrogate is validated on the new real evaluations
%        (out-of-sample RMSE) and then refitted with them.
%     5. If alpha has not improved for StagnationLimit iterations, the
%        least-certain candidates (highest sigma) are also evaluated, which
%        pushes the pack out of a local minimum.
%
%   The baseline gets the SAME budget of real evaluations, so the two
%   convergence curves can be compared against evaluations spent.
%
%   Name-value options:
%       NumNodes, NumWolves, MaxIterations, NumProposals, EvalFraction,
%       StagnationLimit, Seed, RunBaseline, Verbose
%
%   Requires the Statistics and Machine Learning Toolbox (fitrgp).

    arguments
        options.NumNodes (1,1) double {mustBeInteger, mustBePositive} = 20
        options.NumWolves (1,1) double {mustBeInteger, mustBePositive} = 30
        options.MaxIterations (1,1) double {mustBeInteger, mustBePositive} = 60
        options.NumProposals (1,1) double {mustBeInteger, mustBePositive} = 8
        options.EvalFraction (1,1) double {mustBeInRange(options.EvalFraction, 0, 1, 'exclude-lower')} = 0.3
        options.StagnationLimit (1,1) double {mustBeInteger, mustBePositive} = 5
        options.Seed (1,1) double = 42
        options.RunBaseline (1,1) logical = true
        options.Verbose (1,1) logical = true
    end

    project_root = fileparts(mfilename('fullpath'));
    addpath(project_root);

    env = network.NetworkEnv('NumNodes', options.NumNodes);
    objective_fn = @(X) env.evaluatePopulation(X);

    % --- Hybrid SMAC-GWO ---
    rng(options.Seed);
    hybrid = runHybrid(env, objective_fn, options);

    % --- Baseline: plain GWO with the same real-evaluation budget ---
    baseline = struct();
    if options.RunBaseline
        rng(options.Seed);
        baseline = runBaseline(env, objective_fn, options, hybrid.num_evaluations);
    end

    results = struct('env', env, 'hybrid', hybrid, 'baseline', baseline, 'options', options);

    if options.Verbose
        fprintf('\nHybrid SMAC-GWO : best fitness %.5f using %d evaluations\n', ...
            hybrid.best_fitness, hybrid.num_evaluations);
        if options.RunBaseline
            fprintf('Plain GWO       : best fitness %.5f using %d evaluations\n', ...
                baseline.best_fitness, baseline.num_evaluations);
        end
    end
end

% ======================================================================
%  Hybrid loop
% ======================================================================
function result = runHybrid(env, objective_fn, options)
    num_wolves = options.NumWolves;
    num_real = max(1, round(options.EvalFraction * num_wolves));   % real evaluations per iteration

    engine = optimizer.GWOEngine(env.lowerBounds(), env.upperBounds(), ...
        'NumWolves', num_wolves, 'MaxIterations', options.MaxIterations);
    surrogate = optimizer.SMACSurrogate(env.lowerBounds(), env.upperBounds(), ...
        'Acquisition', "EI");

    % Initial pack is evaluated for real: it seeds both GWO and the GP.
    positions = engine.initializePack();
    fitness = objective_fn(positions);
    engine.receiveFitness(positions, fitness);
    surrogate.addObservations(positions, fitness);

    rmse_history = nan(options.MaxIterations, 1);
    eval_history = nan(options.MaxIterations + 1, 1);
    eval_history(1) = engine.NumEvaluations;
    stall_count = 0;

    for iter = 1:options.MaxIterations
        previous_alpha = engine.AlphaFitness;

        % Step 1: several GWO moves per wolf, stacked in NumProposals blocks.
        proposals = engine.proposeCandidates(options.NumProposals);

        if ~surrogate.isReady()
            % Not enough data for a GP yet: fall back to plain GWO.
            candidates = proposals(1:num_wolves, :);
            is_evaluated = true(num_wolves, 1);
            fitness = objective_fn(candidates);
        else
            % Step 2: keep each wolf's best proposal according to the acquisition.
            [~, info] = surrogate.screen(proposals, 1);
            score = reshape(info.score, num_wolves, options.NumProposals);
            [best_score, best_k] = max(score, [], 2);
            pick = sub2ind([num_wolves, options.NumProposals], (1:num_wolves)', best_k);
            candidates = proposals(pick, :);
            predicted_mu = info.mu(pick);
            predicted_sigma = info.sigma(pick);

            % Step 3: send only the most promising wolves to the simulator.
            [~, order] = sort(best_score, 'descend');
            is_evaluated = false(num_wolves, 1);
            is_evaluated(order(1:num_real)) = true;

            % Step 5: on stagnation, also evaluate the most uncertain wolves.
            if stall_count >= options.StagnationLimit
                [~, uncertain] = sort(predicted_sigma, 'descend');
                uncertain = uncertain(~is_evaluated(uncertain));
                is_evaluated(uncertain(1:min(num_real, numel(uncertain)))) = true;
                stall_count = 0;
            end

            fitness = predicted_mu;
            fitness(is_evaluated) = objective_fn(candidates(is_evaluated, :));

            % Step 4: out-of-sample check, then learn from the new data.
            rmse_history(iter) = surrogate.validationRMSE( ...
                candidates(is_evaluated, :), fitness(is_evaluated));
        end

        surrogate.addObservations(candidates(is_evaluated, :), fitness(is_evaluated));
        engine.receiveFitness(candidates, fitness, is_evaluated);
        eval_history(iter + 1) = engine.NumEvaluations;

        if engine.AlphaFitness < previous_alpha
            stall_count = 0;
        else
            stall_count = stall_count + 1;
        end
    end

    result = engine.getResult();
    result.evaluations = eval_history;
    result.surrogate_rmse = rmse_history;
end

% ======================================================================
%  Baseline loop
% ======================================================================
function result = runBaseline(env, objective_fn, options, evaluation_budget)
    % Plain GWO, with as many iterations as the hybrid's budget allows.
    num_wolves = options.NumWolves;
    num_iterations = max(1, floor(evaluation_budget / num_wolves) - 1);

    engine = optimizer.GWOEngine(env.lowerBounds(), env.upperBounds(), ...
        'NumWolves', num_wolves, 'MaxIterations', num_iterations);
    result = engine.run(objective_fn);
    result.evaluations = num_wolves * (1:numel(result.history))';
end

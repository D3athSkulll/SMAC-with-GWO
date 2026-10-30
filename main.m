function results = main(options)
%MAIN  Tune S-MAC (Sensor-MAC) parameters with the Grey Wolf Optimizer.
%
%   results = main() builds a fixed wireless sensor network, then lets GWO
%   search the S-MAC settings that balance energy, delay and delivery:
%
%       x = [duty_cycle, frame_length, contention_window, sync_period]
%
%   Every candidate x is scored by running the S-MAC simulator
%   (network.SMACProtocol) on the same nodes, routes and traffic.
%
%   Two baselines put the result in context:
%     * Default S-MAC  - the usual fixed setting (10% duty cycle, 1 s frame,
%                        CW 32, SYNC every 10 frames), no optimisation.
%     * Random search  - uniform random settings with the SAME number of
%                        simulations as GWO. GWO must beat this to show the
%                        hunting strategy helps, not just the budget.
%
%   Name-value options:
%       NumNodes, NumWolves, MaxIterations, Seed, RunBaselines, Verbose
%       IterationCallback  @(progress) called after every iteration of both
%                          searches; progress has fields run ("gwo" or
%                          "random"), iteration, best_fitness, best_position,
%                          diversity, evaluations. simulate.m uses it for
%                          live plotting.

    arguments
        options.NumNodes (1,1) double {mustBeInteger, mustBePositive} = 20
        options.NumWolves (1,1) double {mustBeInteger, mustBePositive} = 30
        options.MaxIterations (1,1) double {mustBeInteger, mustBePositive} = 40
        options.Seed (1,1) double = 42
        options.RunBaselines (1,1) logical = true
        options.Verbose (1,1) logical = true
        options.IterationCallback = []
    end

    project_root = fileparts(mfilename('fullpath'));
    addpath(project_root, fullfile(project_root, 'utils'));

    env = network.NetworkEnv('NumNodes', options.NumNodes);
    mac = network.SMACProtocol(env);
    objective_fn = @(X) mac.evaluatePopulation(X);

    % --- GWO-tuned S-MAC ---
    rng(options.Seed);
    gwo = runGWO(mac, objective_fn, options);

    % --- Baselines ---
    default_run = struct();
    random_run = struct();
    if options.RunBaselines
        [default_run.fitness, default_run.metrics] = mac.evaluate(mac.defaultParameters());
        default_run.position = mac.defaultParameters();
        rng(options.Seed);
        random_run = runRandomSearch(mac, objective_fn, options, gwo.num_evaluations);
    end

    results = struct('env', env, 'mac', mac, 'gwo', gwo, 'random_search', random_run, ...
                     'default', default_run, 'options', options);

    summary = LogManager("Summary", 'Enabled', options.Verbose);
    summary.info('GWO-tuned S-MAC : fitness %.4f | %s', gwo.best_fitness, describe(gwo.best_metrics));
    if options.RunBaselines
        summary.info('Random search   : fitness %.4f | %s', random_run.best_fitness, describe(random_run.best_metrics));
        summary.info('Default S-MAC   : fitness %.4f | %s', default_run.fitness, describe(default_run.metrics));
    end
end

% ======================================================================
%  GWO loop
% ======================================================================
function result = runGWO(mac, objective_fn, options)
    engine = optimizer.GWOEngine(mac.lowerBounds(), mac.upperBounds(), ...
        'NumWolves', options.NumWolves, 'MaxIterations', options.MaxIterations);
    logger = newLogger("GWO-tuned S-MAC", options);
    logger.header();

    % Hunt: evaluate the pack, update alpha/beta/delta, move, repeat.
    positions = engine.initializePack();
    engine.receiveFitness(positions, objective_fn(positions));
    report("gwo", 0, engine.AlphaPosition, engine.AlphaFitness, engine.diversityIndex(), ...
           engine.NumEvaluations, mac, logger, options);
    for iter = 1:options.MaxIterations
        candidates = engine.proposeCandidates();
        engine.receiveFitness(candidates, objective_fn(candidates));
        report("gwo", iter, engine.AlphaPosition, engine.AlphaFitness, engine.diversityIndex(), ...
               engine.NumEvaluations, mac, logger, options);
    end
    logger.footer();

    result = engine.getResult();
    result.evaluations = options.NumWolves * (1:numel(result.history))';
    [~, result.best_metrics] = mac.evaluate(result.best_position);
end

% ======================================================================
%  Random-search baseline (same evaluation budget)
% ======================================================================
function result = runRandomSearch(mac, objective_fn, options, evaluation_budget)
    lb = mac.lowerBounds();
    ub = mac.upperBounds();
    batch_size = options.NumWolves;
    num_batches = ceil(evaluation_budget / batch_size);
    logger = newLogger("Random search baseline", options);
    logger.header();

    best_fitness = Inf;
    best_position = nan(1, numel(lb));
    history = zeros(num_batches, 1);
    for batch = 1:num_batches
        samples = lb + rand(batch_size, numel(lb)) .* (ub - lb);
        fitness = objective_fn(samples);
        [batch_best, idx] = min(fitness);
        if batch_best < best_fitness
            best_fitness = batch_best;
            best_position = samples(idx, :);
        end
        history(batch) = best_fitness;
        report("random", batch - 1, best_position, best_fitness, NaN, batch * batch_size, ...
               mac, logger, options);
    end
    logger.footer();

    [~, best_metrics] = mac.evaluate(best_position);
    result = struct('best_position', best_position, 'best_fitness', best_fitness, ...
                    'history', history, 'evaluations', batch_size * (1:num_batches)', ...
                    'num_evaluations', num_batches * batch_size, 'best_metrics', best_metrics);
end

% ======================================================================
%  Logging and progress reporting shared by both searches
% ======================================================================
function logger = newLogger(title, options)
    columns = struct( ...
        'name',   {'Iteration', 'Best Fitness', 'Duty Cycle', 'Frame (s)', 'CW', 'SYNC', 'Diversity', 'Evals'}, ...
        'width',  {9, 12, 10, 9, 4, 4, 9, 6}, ...
        'format', {'%d', '%.5f', '%.1f%%', '%.3f', '%d', '%d', '%.4f', '%d'});
    logger = LogManager(title, columns, 'Enabled', options.Verbose);
end

function report(run_name, iter, best_position, best_fitness, diversity, evaluations, mac, logger, options)
    params = mac.decode(best_position);
    logger.row({iter, best_fitness, 100 * params.duty_cycle, params.frame_length, ...
                params.contention_window, params.sync_period, diversity, evaluations});
    if ~isempty(options.IterationCallback)
        progress = struct('run', run_name, 'iteration', iter, 'best_fitness', best_fitness, ...
                          'best_position', best_position, 'diversity', diversity, ...
                          'evaluations', evaluations);
        options.IterationCallback(progress);
    end
end

function text = describe(metrics)
    p = metrics.params;
    text = sprintf(['duty %.1f%%, frame %.2f s, CW %d, SYNC %d -> PDR %.1f%%, delay %.2f s, ' ...
                    'power %.2f mW, lifetime %.0f days'], 100 * p.duty_cycle, p.frame_length, ...
                   p.contention_window, p.sync_period, 100 * metrics.pdr, metrics.mean_delay, ...
                   1e3 * metrics.mean_power, metrics.lifetime_days);
end

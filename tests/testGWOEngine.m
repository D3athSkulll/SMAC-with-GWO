%TESTGWOENGINE  Sanity checks for optimizer.GWOEngine. Run from the project root.

addpath(pwd);
rng(1);

%% Test 1: converges on the sphere function (global minimum 0 at the origin)
dim = 10;
sphere_fn = @(X) sum(X.^2, 2);
engine = optimizer.GWOEngine(-10 * ones(1, dim), 10 * ones(1, dim), ...
                             'NumWolves', 30, 'MaxIterations', 200);
result = engine.run(sphere_fn);
assert(result.best_fitness < 1e-3, 'Test 1 failed: did not converge on sphere');

%% Test 2: leaders are ordered alpha <= beta <= delta
assert(engine.AlphaFitness <= engine.BetaFitness && engine.BetaFitness <= engine.DeltaFitness, ...
    'Test 2 failed: leader ordering');

%% Test 3: elitism -> best fitness history never increases
assert(all(diff(result.history) <= 0), 'Test 3 failed: best fitness got worse');

%% Test 4: evaluation budget = pack size * (initial pack + one per iteration)
assert(result.num_evaluations == 30 * (200 + 1), 'Test 4 failed: evaluation count');

%% Test 5: control parameter a decays from 2 toward 0
engine = optimizer.GWOEngine([0 0], [1 1], 'NumWolves', 10, 'MaxIterations', 10);
assert(engine.controlParameter() == 2, 'Test 5 failed: a should start at 2');
positions = engine.initializePack();
engine.receiveFitness(positions, sum(positions.^2, 2));
for k = 1:5
    engine.proposeCandidates();
end
assert(abs(engine.controlParameter() - 1) < 1e-12, 'Test 5 failed: a should be 1 at half time');

%% Test 6: candidates stay inside the bounds
lb = [-5 0 10]; ub = [5 1 20];
engine = optimizer.GWOEngine(lb, ub, 'NumWolves', 12, 'MaxIterations', 5);
positions = engine.initializePack();
engine.receiveFitness(positions, sum(positions.^2, 2));
candidates = engine.proposeCandidates();
assert(all(candidates >= lb, 'all') && all(candidates <= ub, 'all'), ...
    'Test 6 failed: bounds violated');

%% Test 7: diversity collapses as the pack converges
assert(result.diversity(end) < result.diversity(1), 'Test 7 failed: diversity did not shrink');

%% Test 8: GWO improves S-MAC parameters on the sensor network
mac = network.SMACProtocol(network.NetworkEnv('NumNodes', 20));
engine = optimizer.GWOEngine(mac.lowerBounds(), mac.upperBounds(), ...
                             'NumWolves', 10, 'MaxIterations', 10);
result = engine.run(@(X) mac.evaluatePopulation(X));
assert(result.best_fitness <= result.history(1), 'Test 8 failed: no improvement');
[~, metrics] = mac.evaluate(result.best_position);
fprintf('S-MAC GWO: fitness %.4f -> %.4f | duty %.1f%% | frame %.2f s | PDR %.1f%%\n', ...
    result.history(1), result.best_fitness, 100 * metrics.params.duty_cycle, ...
    metrics.params.frame_length, 100 * metrics.pdr);

disp('All GWOEngine tests passed.');

%TESTSMACSURROGATE  Sanity checks for optimizer.SMACSurrogate. Run from the project root.

addpath(pwd);
rng(7);

%% Test 1: Expected Improvement behaves as theory says
% MinTrainingSize is large so no GP is fitted; EI only needs BestObserved.
sur = optimizer.SMACSurrogate([0 0], [1 1], 'MinTrainingSize', 50);
sur.addObservations(rand(5, 2), [1 2 3 4 5]');          % BestObserved = 1
tiny = 1e-9;
assert(abs(sur.acquisitionScore(0.5, tiny) - 0.5) < 1e-6, 'Test 1a failed: EI should equal sure improvement');
assert(abs(sur.acquisitionScore(2.0, tiny)) < 1e-6,        'Test 1b failed: EI should vanish when no improvement possible');
assert(sur.acquisitionScore(1, 0.5) > sur.acquisitionScore(1, 0.1), 'Test 1c failed: EI should grow with uncertainty');
assert(sur.acquisitionScore(0.5, 0.2) > sur.acquisitionScore(1.5, 0.2), 'Test 1d failed: EI should favour lower mean');

%% Test 2: LCB score is -(mu - kappa*sigma)
lcb = optimizer.SMACSurrogate([0 0], [1 1], 'MinTrainingSize', 50, ...
                              'Acquisition', 'LCB', 'ConfidenceWeight', 2);
assert(abs(lcb.acquisitionScore(1, 0.5) - 0) < 1e-12, 'Test 2 failed: LCB score');

%% Test 3: GP learns a smooth function (2-D sphere on [-5,5]^2)
lb = [-5 -5]; ub = [5 5];
sphere_fn = @(X) sum(X.^2, 2);
sur = optimizer.SMACSurrogate(lb, ub, 'MinTrainingSize', 20);
X_train = lb + rand(60, 2) .* (ub - lb);
sur.addObservations(X_train, sphere_fn(X_train));
assert(sur.isReady(), 'Test 3 failed: surrogate should be ready');

X_test = lb + rand(100, 2) .* (ub - lb);
rmse = sur.validationRMSE(X_test, sphere_fn(X_test));
assert(rmse < 1.5, 'Test 3 failed: GP error too large (RMSE %.3f, range ~50)', rmse);

%% Test 4: screening ranks a candidate near the optimum first
candidates = [4 4; -4 4; 0.1 -0.1; 4 -4; -4 -4; 2 2];
[selected_idx, info] = sur.screen(candidates, 2);
assert(selected_idx(1) == 3, 'Test 4 failed: expected the near-origin candidate first');
assert(all(info.sigma > 0) && numel(info.score) == 6, 'Test 4 failed: info fields');

%% Test 5: predicting before enough data raises a clear error
empty_sur = optimizer.SMACSurrogate(lb, ub);
did_error = false;
try
    empty_sur.predictFitness([0 0]);
catch err
    did_error = strcmp(err.identifier, 'SMACSurrogate:notReady');
end
assert(did_error, 'Test 5 failed: expected SMACSurrogate:notReady');
assert(isnan(empty_sur.validationRMSE([0 0], 1)), 'Test 5 failed: RMSE should be NaN when not ready');

%% Test 6: training window is capped but the best point is kept
capped = optimizer.SMACSurrogate(lb, ub, 'MaxTrainingSize', 100, 'MinTrainingSize', 20);
X_many = lb + rand(500, 2) .* (ub - lb);
capped.addObservations(X_many, sphere_fn(X_many));
assert(numel(capped.TrainTargets) == 100, 'Test 6 failed: window size');
assert(min(capped.TrainTargets) == capped.BestObserved, 'Test 6 failed: best point dropped');

%% Test 7: validationRMSE matches a manual computation
mu = sur.predictFitness(X_test);
manual = sqrt(mean((mu - sphere_fn(X_test)).^2));
assert(abs(manual - rmse) < 1e-12, 'Test 7 failed: RMSE mismatch');

%% Test 8: surrogate on the sensor network problem (informational + loose check)
env = network.NetworkEnv('NumNodes', 20);
sur = optimizer.SMACSurrogate(env.lowerBounds(), env.upperBounds(), 'MinTrainingSize', 40);
X_net = env.sampleRandom(80);
y_net = env.evaluatePopulation(X_net);
sur.addObservations(X_net(1:60, :), y_net(1:60));
rmse_net = sur.validationRMSE(X_net(61:80, :), y_net(61:80));
fprintf('Network surrogate: out-of-sample RMSE %.4f vs fitness std %.4f\n', rmse_net, std(y_net(61:80)));
assert(isfinite(rmse_net) && rmse_net < 2 * std(y_net(61:80)), 'Test 8 failed: surrogate is worse than useless');

disp('All SMACSurrogate tests passed.');

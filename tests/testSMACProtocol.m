%TESTSMACPROTOCOL  Sanity checks for network.SMACProtocol. Run from the project root.

addpath(pwd);

env = network.NetworkEnv('NumNodes', 20);
mac = network.SMACProtocol(env);
x_default = mac.defaultParameters();

%% Test 1: evaluation is deterministic (common random numbers)
[f1, m1] = mac.evaluate(x_default);
[f2, ~] = mac.evaluate(x_default);
assert(f1 == f2, 'Test 1 failed: same parameters gave different fitness');

%% Test 2: every packet is delivered, dropped or still queued
for x = {x_default, [0.03 1.5 8 30], [0.2 0.3 64 2]}
    [~, m] = mac.evaluate(x{1});
    accounted = m.num_delivered + m.drops_queue + m.drops_retry + m.num_queued;
    assert(accounted == m.num_generated, 'Test 2 failed: packets lost from the books');
    assert(m.pdr >= 0 && m.pdr <= 1, 'Test 2 failed: PDR out of range');
end

%% Test 3: decode clips to the bounds and rounds the integer parameters
p = mac.decode([0.001 5 31.6 0.2]);
assert(p.duty_cycle == mac.LowerBound(1) && p.frame_length == mac.UpperBound(2), 'Test 3 failed: clipping');
assert(p.contention_window == 32 && p.sync_period == mac.LowerBound(4), 'Test 3 failed: rounding');

%% Test 4: a listen period too short for SYNC + RTS/CTS delivers nothing
[~, m] = mac.evaluate([0.02 0.2 32 10]);         % listen = 4 ms
assert(m.effective_cw == 0 && m.num_delivered == 0, 'Test 4 failed: impossible schedule delivered packets');

%% Test 5: energy grows with the duty cycle (same frame length)
[~, low] = mac.evaluate([0.10 0.5 32 10]);
[~, high] = mac.evaluate([0.40 0.5 32 10]);
assert(high.mean_power > low.mean_power, 'Test 5 failed: more listening should cost more energy');
assert(high.lifetime_days < low.lifetime_days, 'Test 5 failed: lifetime should drop');

%% Test 6: delay grows with the frame length (one hop per frame)
[~, short_frame] = mac.evaluate([0.15 0.3 32 10]);
[~, long_frame] = mac.evaluate([0.15 1.0 32 10]);
assert(long_frame.mean_delay > short_frame.mean_delay, 'Test 6 failed: longer frames should add delay');

%% Test 7: power lies between the sleep power and the always-on power
assert(m1.mean_power > env.PowerSleep && m1.peak_power < env.PowerTx, 'Test 7 failed: power out of range');

%% Test 8: rarer SYNC means a higher chance of missing the receiver
[~, frequent] = mac.evaluate([0.05 1.0 16 1]);
[~, rare] = mac.evaluate([0.05 1.0 16 30]);
assert(rare.p_miss > frequent.p_miss, 'Test 8 failed: drift model');

fprintf('Default S-MAC: fitness %.4f | PDR %.1f%% | delay %.2f s | power %.2f mW | lifetime %.0f days\n', ...
    f1, 100 * m1.pdr, m1.mean_delay, 1e3 * m1.mean_power, m1.lifetime_days);
disp('All SMACProtocol tests passed.');

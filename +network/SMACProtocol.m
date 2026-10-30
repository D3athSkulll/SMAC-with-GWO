classdef SMACProtocol
    %SMACPROTOCOL  Frame-level simulator of S-MAC (Ye, Heidemann & Estrin, 2002).
    %
    %   S-MAC saves energy by letting nodes sleep most of the time. Time is
    %   divided into frames of length T; each frame has a listen period
    %   L = duty_cycle * T followed by a sleep period:
    %
    %     |<---------------------------- frame T ---------------------------->|
    %     | SYNC window | contention + RTS/CTS |  DATA/ACK (only the pair)  ...  sleep |
    %     |<--------- listen L = d*T --------->|
    %
    %   * SYNC: every SyncPeriod frames each node broadcasts its schedule so
    %     neighbours stay aligned. Between SYNCs the clocks drift apart; if the
    %     drift is large compared with L, an exchange can miss the receiver.
    %   * Contention: a node with a queued packet picks a random slot in
    %     [0, CW-1]. Carrier sense: it defers if a neighbour started earlier.
    %     Same-slot neighbours, and hidden terminals that overlap at the
    %     receiver, cause an RTS collision. Failed attempts are retried up to
    %     MaxRetries times, then the packet is dropped.
    %   * Exchange: RTS/CTS inside the listen period, then DATA/ACK. The two
    %     nodes stay awake for it; everyone else follows the schedule
    %     (overhearing avoidance). One packet per node per frame, one hop per
    %     frame (no adaptive listening).
    %
    %   Decision vector tuned by GWO (all continuous; CW and SyncPeriod are
    %   rounded to integers):
    %       x = [duty_cycle, frame_length (s), contention_window (slots), sync_period (frames)]
    %
    %   Fitness (minimise):
    %       f = w_E * P_mean / P_idle  +  w_D * min(delay / D_ref, 1)  +  w_P * (1 - PDR)
    %   P_mean / P_idle is the mean node power relative to an always-on radio.
    %
    %   Each evaluation uses the same nodes, routes, packets and contention
    %   random numbers, so the fitness is deterministic for a given x.
    %
    %   Typical use:
    %       env = network.NetworkEnv();
    %       mac = network.SMACProtocol(env);
    %       [fitness, metrics] = mac.evaluate(mac.defaultParameters());

    properties (Constant)
        ParameterNames = {'Duty cycle', 'Frame length (s)', 'Contention window (slots)', 'SYNC period (frames)'}
    end

    properties (SetAccess = immutable)
        Env                 % network.NetworkEnv
        LowerBound          % 1 x 4
        UpperBound          % 1 x 4
        SlotTime            % contention slot length (s)
        SyncSlots           % contention slots reserved for SYNC at the start of each listen period
        MaxRetries          % failed attempts before a packet is dropped
        QueueLimit          % packets a node can buffer
        ClockDriftPPM       % crystal drift of each node (parts per million)
        DelayReference      % delay that counts as "fully bad" in the fitness (s)
        Weights             % [w_energy w_delay w_pdr], sums to 1
        ContentionSeed      % seed of the per-evaluation contention random numbers
    end

    methods
        function obj = SMACProtocol(env, options)
            arguments
                env (1,1) network.NetworkEnv
                options.LowerBound (1,4) double = [0.02 0.2 4 1]
                options.UpperBound (1,4) double = [0.50 2.0 128 30]
                options.SlotTime (1,1) double {mustBePositive} = 1e-3
                options.SyncSlots (1,1) double {mustBeInteger, mustBeNonnegative} = 16
                options.MaxRetries (1,1) double {mustBeInteger, mustBeNonnegative} = 5
                options.QueueLimit (1,1) double {mustBeInteger, mustBePositive} = 10
                options.ClockDriftPPM (1,1) double {mustBeNonnegative} = 50
                options.DelayReference (1,1) double {mustBePositive} = 10
                options.Weights (1,3) double {mustBeNonnegative} = [0.3 0.3 0.4]
                options.ContentionSeed (1,1) double = 3
            end
            assert(all(options.UpperBound > options.LowerBound), 'SMACProtocol:badBounds', ...
                'UpperBound must exceed LowerBound.');
            assert(options.LowerBound(1) > 0 && options.UpperBound(1) <= 1, 'SMACProtocol:badBounds', ...
                'Duty cycle bounds must lie in (0, 1].');
            assert(sum(options.Weights) > 0, 'SMACProtocol:badWeights', ...
                'At least one objective weight must be positive.');

            obj.Env = env;
            obj.LowerBound = options.LowerBound;
            obj.UpperBound = options.UpperBound;
            obj.SlotTime = options.SlotTime;
            obj.SyncSlots = options.SyncSlots;
            obj.MaxRetries = options.MaxRetries;
            obj.QueueLimit = options.QueueLimit;
            obj.ClockDriftPPM = options.ClockDriftPPM;
            obj.DelayReference = options.DelayReference;
            obj.Weights = options.Weights / sum(options.Weights);
            obj.ContentionSeed = options.ContentionSeed;
        end

        function lb = lowerBounds(obj)
            lb = obj.LowerBound;
        end

        function ub = upperBounds(obj)
            ub = obj.UpperBound;
        end

        function x = defaultParameters(~)
            %DEFAULTPARAMETERS  Typical fixed S-MAC setting used as the baseline:
            %   10% duty cycle, 1 s frame, 32-slot contention window, SYNC every 10 frames.
            x = [0.10 1.0 32 10];
        end

        function params = decode(obj, x)
            %DECODE  Decision vector -> named, clipped, integer-rounded parameters.
            x = min(max(reshape(x, 1, []), obj.LowerBound), obj.UpperBound);
            params = struct( ...
                'duty_cycle',   x(1), ...
                'frame_length', x(2), ...
                'contention_window', round(x(3)), ...
                'sync_period',  round(x(4)));
        end

        function [fitness, metrics] = evaluate(obj, x)
            %EVALUATE  Simulate S-MAC with parameters x; scalar fitness + metrics.
            params = obj.decode(x);
            metrics = obj.simulate(params);

            energy_norm = metrics.mean_power / obj.Env.PowerIdle;
            if isnan(metrics.mean_delay)
                delay_norm = 1;                 % nothing delivered: worst delay score
            else
                delay_norm = min(metrics.mean_delay / obj.DelayReference, 1);
            end
            fitness = obj.Weights(1) * energy_norm ...
                    + obj.Weights(2) * delay_norm ...
                    + obj.Weights(3) * (1 - metrics.pdr);

            metrics.fitness = fitness;
            metrics.energy_norm = energy_norm;
            metrics.delay_norm = delay_norm;
        end

        function fitness = evaluatePopulation(obj, X)
            %EVALUATEPOPULATION  Fitness for each row of X (pop_size x 4).
            fitness = zeros(size(X, 1), 1);
            for k = 1:size(X, 1)
                fitness(k) = obj.evaluate(X(k, :));
            end
        end

        function metrics = simulate(obj, params)
            %SIMULATE  Run the frame-by-frame S-MAC simulation.
            env = obj.Env;
            num_nodes = env.NumNodes;
            sink = num_nodes + 1;
            stream = RandStream('mt19937ar', 'Seed', obj.ContentionSeed);

            % --- Timing of one frame ---
            frame = params.frame_length;
            listen = params.duty_cycle * frame;
            t_ctrl = env.airTime(env.ControlBytes);     % RTS, CTS or ACK
            t_data = env.airTime(env.DataBytes);
            t_sync = env.airTime(env.SyncBytes);
            sync_window = obj.SyncSlots * obj.SlotTime + t_sync;

            % The contention window must fit in the listen period together with
            % RTS and CTS; a window that does not fit is cut short.
            room_for_slots = (listen - sync_window - 2 * t_ctrl) / obj.SlotTime;
            cw = min(params.contention_window, floor(room_for_slots));
            can_contend = cw >= 1;
            rts_slots = t_ctrl / obj.SlotTime;          % RTS length in slots (for overlap)

            % Clock drift: two nodes drift apart at up to 2*ppm; on average
            % half a SYNC period has passed since the last resync.
            drift_rate = 2 * obj.ClockDriftPPM * 1e-6;
            mean_misalignment = drift_rate * params.sync_period * frame / 2;
            p_miss = min(1, mean_misalignment / listen);

            % --- State ---
            num_frames = floor(env.SimulationTime / frame);
            queue = zeros(num_nodes, obj.QueueLimit);   % generation time of each buffered packet
            queue_len = zeros(num_nodes, 1);
            retries = zeros(num_nodes, 1);              % failed attempts of each head packet
            energy = zeros(num_nodes, 1);               % energy above the schedule baseline (J)

            num_generated = env.numPackets();
            delays = nan(num_generated, 1);
            num_delivered = 0;
            drops_queue = 0;
            drops_retry = 0;
            num_attempts = 0;
            num_collisions = 0;
            next_arrival = 1;

            for f = 1:num_frames
                frame_start = (f - 1) * frame;

                % 1. Packets generated since the last frame join their node's queue.
                while next_arrival <= num_generated && env.ArrivalTimes(next_arrival) < frame_start
                    node = env.ArrivalNodes(next_arrival);
                    [queue, queue_len, dropped] = obj.push(queue, queue_len, node, env.ArrivalTimes(next_arrival));
                    drops_queue = drops_queue + dropped;
                    next_arrival = next_arrival + 1;
                end

                % 2. SYNC broadcast (every node, every sync_period frames).
                if mod(f, params.sync_period) == 0
                    energy = energy + (env.PowerTx - env.PowerIdle) * t_sync;
                end

                contenders = find(queue_len > 0);
                if ~can_contend || isempty(contenders)
                    continue;
                end

                % 3. Contention: random slot, carrier sense, collisions at the receiver.
                num_contenders = numel(contenders);
                slot = randi(stream, cw, num_contenders, 1) - 1;
                missed = rand(stream, num_contenders, 1) < p_miss;
                receiver = env.NextHop(contenders);

                hears = env.Neighbors(contenders, contenders);
                started_earlier = slot' < slot;                 % (i,j): j picked an earlier slot than i
                defers = any(hears & started_earlier, 2);
                sends_rts = ~defers;

                overlap = abs(slot - slot') < rts_slots & ~eye(num_contenders);
                heard_at_receiver = env.Neighbors(receiver, contenders);   % (i,j): rx of i hears j
                interfered = any(overlap & heard_at_receiver & sends_rts', 2);
                receiver_busy = ismember(receiver, contenders(sends_rts));  % half-duplex
                success = sends_rts & ~interfered & ~receiver_busy & ~missed;

                % One exchange per receiver: the earliest slot wins, later
                % senders hear the CTS and back off without a retry penalty.
                [~, by_slot] = sort(slot);
                winners = by_slot(success(by_slot));
                [~, first] = unique(receiver(winners), 'stable');
                backed_off = setdiff(winners, winners(first));
                success(backed_off) = false;
                failed = sends_rts & ~success;
                failed(backed_off) = false;

                num_attempts = num_attempts + nnz(sends_rts);
                num_collisions = num_collisions + nnz(sends_rts & (interfered | receiver_busy));

                % 4. Energy above the listen/sleep baseline.
                rts_nodes = contenders(sends_rts);
                energy(rts_nodes) = energy(rts_nodes) + (env.PowerTx - env.PowerIdle) * t_ctrl;
                senders = contenders(success);
                relays = receiver(success);
                relays = relays(relays ~= sink);                % the sink is mains powered
                energy(senders) = energy(senders) + (env.PowerTx - env.PowerSleep) * t_data ...
                                                  + (env.PowerRx - env.PowerSleep) * t_ctrl;
                energy(relays) = energy(relays) + (env.PowerTx - env.PowerIdle) * t_ctrl ...
                                                + (env.PowerRx - env.PowerSleep) * t_data ...
                                                + (env.PowerTx - env.PowerSleep) * t_ctrl;

                % 5. Move delivered packets one hop forward.
                delivery_time = frame_start + sync_window + (slot + 1) * obj.SlotTime ...
                              + 3 * t_ctrl + t_data;
                for k = find(success)'
                    node = contenders(k);
                    [queue, queue_len, born] = obj.pop(queue, queue_len, node);
                    retries(node) = 0;
                    if receiver(k) == sink
                        num_delivered = num_delivered + 1;
                        delays(num_delivered) = delivery_time(k) - born;
                    else
                        [queue, queue_len, dropped] = obj.push(queue, queue_len, receiver(k), born);
                        drops_queue = drops_queue + dropped;
                    end
                end

                % 6. Failed attempts: retry, or drop after MaxRetries.
                for node = contenders(failed)'
                    retries(node) = retries(node) + 1;
                    if retries(node) > obj.MaxRetries
                        [queue, queue_len] = obj.pop(queue, queue_len, node);
                        retries(node) = 0;
                        drops_retry = drops_retry + 1;
                    end
                end
            end

            % --- Totals ---
            simulated_time = num_frames * frame;
            baseline_energy = num_frames * (env.PowerIdle * listen + env.PowerSleep * (frame - listen));
            node_energy = baseline_energy + energy;
            node_power = node_energy / simulated_time;
            delays = delays(1:num_delivered);

            metrics = struct( ...
                'params',            params, ...
                'pdr',               num_delivered / max(num_generated, 1), ...
                'mean_delay',        mean(delays), ...          % NaN if nothing was delivered
                'mean_power',        mean(node_power), ...
                'peak_power',        max(node_power), ...
                'node_power',        node_power, ...
                'lifetime_days',     env.BatteryEnergy / max(node_power) / 86400, ...
                'energy_per_packet', sum(node_energy) / max(num_delivered, 1), ...
                'num_generated',     num_generated, ...
                'num_delivered',     num_delivered, ...
                'drops_queue',       drops_queue, ...
                'drops_retry',       drops_retry, ...
                'num_queued',        sum(queue_len), ...        % still buffered at the end
                'collision_rate',    num_collisions / max(num_attempts, 1), ...
                'effective_cw',      max(cw, 0), ...
                'listen_time',       listen, ...
                'p_miss',            p_miss);
        end
    end

    methods (Access = private)
        function [queue, queue_len, dropped] = push(obj, queue, queue_len, node, born)
            %PUSH  Append a packet to a node's FIFO; drop it if the buffer is full.
            dropped = queue_len(node) >= obj.QueueLimit;
            if ~dropped
                queue_len(node) = queue_len(node) + 1;
                queue(node, queue_len(node)) = born;
            end
        end

        function [queue, queue_len, born] = pop(~, queue, queue_len, node)
            %POP  Remove and return the head-of-line packet of a node.
            born = queue(node, 1);
            queue(node, 1:end-1) = queue(node, 2:end);
            queue_len(node) = queue_len(node) - 1;
        end
    end
end

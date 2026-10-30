function results = simulate(options, main_options)
%SIMULATE  Run GWO-tuned S-MAC with a live dual-panel figure.
%
%   results = simulate() runs main() and draws, while it runs:
%     Left  (subplot 1,2,1)  Convergence: best fitness against the number of
%                            S-MAC simulations, for GWO and for random
%                            search with the same budget. The default S-MAC
%                            setting is a dashed reference line.
%     Right (subplot 1,2,2)  The sensor network: nodes, sink, radio range
%                            (transmission radius) and the multi-hop routes
%                            S-MAC carries traffic on, with the tuned
%                            parameters and their PDR / delay / power.
%
%   results = simulate('SavePath', 'figure.png', NumNodes=25, ...)
%   simulate's own options come first; anything else is passed to main().
%
%   Uses viscircles (Image Processing Toolbox) when it is installed and
%   draws the circles with plain line objects otherwise.

    arguments
        options.SavePath (1,1) string = ""
        options.Visible (1,1) logical = true
        main_options.NumNodes
        main_options.NumWolves
        main_options.MaxIterations
        main_options.Seed
        main_options.RunBaselines
        main_options.Verbose
    end

    % --- Colours: categorical slots 1 and 2, fixed per run ---
    style.gwo = [42 120 214] / 255;         % blue   #2a78d6
    style.random = [235 104 52] / 255;      % orange #eb6834
    style.ink = [0.25 0.25 0.25];           % nodes, labels, reference line
    style.muted = [0.62 0.62 0.62];         % radii
    style.line_width = 2;

    fig = figure('Name', 'S-MAC tuned by GWO', 'Color', 'w', ...
                 'Position', [100 100 1200 520], 'Visible', matlab.lang.OnOffSwitchState(options.Visible));

    % --- Panel 1: live convergence curves ---
    ax_curve = subplot(1, 2, 1, 'Parent', fig);
    hold(ax_curve, 'on');
    curves.gwo = animatedline(ax_curve, 'Color', style.gwo, 'LineWidth', style.line_width, ...
                              'DisplayName', 'GWO-tuned S-MAC');
    curves.random = animatedline(ax_curve, 'Color', style.random, 'LineWidth', style.line_width, ...
                                 'DisplayName', 'Random search (same budget)');
    styleAxes(ax_curve);
    xlabel(ax_curve, 'S-MAC simulations');
    ylabel(ax_curve, 'Best fitness (lower is better)');
    title(ax_curve, 'Convergence');
    legend(ax_curve, 'Location', 'east', 'Box', 'off');

    % Panel 2 placeholder until GWO finishes.
    ax_layout = subplot(1, 2, 2, 'Parent', fig);
    styleAxes(ax_layout);
    title(ax_layout, 'Sensor network (waiting for GWO)');

    % --- Run the optimisers; the callback feeds the live curves ---
    main_args = namedargs2cell(main_options);
    results = main(main_args{:}, 'IterationCallback', @(p) onIteration(p, curves));

    % --- Final rendering ---
    finishCurves(ax_curve, results, style);
    drawNetwork(ax_layout, results.env, results.gwo.best_metrics, style);

    if strlength(options.SavePath) > 0
        exportgraphics(fig, options.SavePath, 'Resolution', 150);
    end
end

% ======================================================================
function onIteration(progress, curves)
    % Append one point to the curve of the search that just reported.
    addpoints(curves.(progress.run), progress.evaluations, progress.best_fitness);
    drawnow limitrate;
end

function styleAxes(ax)
    % Recessive axes: light grid, no box, muted tick labels.
    set(ax, 'Box', 'off', 'TickDir', 'out', 'XColor', [0.45 0.45 0.45], ...
        'YColor', [0.45 0.45 0.45], 'GridColor', [0.85 0.85 0.85], 'GridAlpha', 1, ...
        'FontSize', 10);
    grid(ax, 'on');
end

function finishCurves(ax, results, style)
    % End markers with values, plus the default S-MAC reference line.
    runs = {'gwo', 'random'};
    fields = {'gwo', 'random_search'};
    finals = inf(1, numel(runs));
    for k = 1:numel(runs)
        if isfield(results.(fields{k}), 'history')
            finals(k) = results.(fields{k}).history(end);
        end
    end
    for k = 1:numel(runs)
        run = results.(fields{k});
        if ~isfield(run, 'history')
            continue;
        end
        x_end = run.evaluations(end);
        y_end = run.history(end);
        plot(ax, x_end, y_end, 'o', 'MarkerSize', 7, 'MarkerFaceColor', style.(runs{k}), ...
             'MarkerEdgeColor', 'w', 'LineWidth', 1.5, 'HandleVisibility', 'off');
        % The lower curve's label goes below its marker, the higher one's above,
        % so close end values do not print on top of each other.
        if y_end <= min(finals)
            alignment = 'top';
        else
            alignment = 'bottom';
        end
        text(ax, x_end, y_end, sprintf('  %.4f', y_end), 'Color', style.ink, ...
             'FontSize', 9, 'VerticalAlignment', alignment);
    end
    xlim(ax, [0, max(xlim(ax)) * 1.12]);   % leave room for the end labels

    if isfield(results.default, 'fitness')
        yline(ax, results.default.fitness, '--', sprintf('Default S-MAC  %.4f', results.default.fitness), ...
              'Color', style.ink, 'LineWidth', 1, 'LabelHorizontalAlignment', 'left', ...
              'FontSize', 9, 'DisplayName', 'Default S-MAC (no tuning)');
    end
    y_range = ylim(ax);
    ylim(ax, [max(0, y_range(1) - 0.05 * diff(y_range)), y_range(2) + 0.08 * diff(y_range)]);
end

function drawNetwork(ax, env, metrics, style)
    % Nodes, sink, transmission radius and the routes S-MAC forwards on.
    positions = env.Positions;
    all_points = [positions; env.SinkPosition];
    cla(ax);
    hold(ax, 'on');

    % Transmission radius (CommRadius) around every node.
    radii = env.CommRadius * ones(env.NumNodes, 1);
    if exist('viscircles', 'file') == 2
        viscircles(ax, positions, radii, 'Color', style.muted, 'LineWidth', 0.5, ...
                   'LineStyle', ':', 'EnhanceVisibility', false);
    else
        theta = linspace(0, 2 * pi, 64);
        circle_x = positions(:, 1) + radii .* cos(theta);     % N x 64 via implicit expansion
        circle_y = positions(:, 2) + radii .* sin(theta);
        plot(ax, circle_x', circle_y', ':', 'Color', style.muted, 'LineWidth', 0.5, ...
             'HandleVisibility', 'off');
    end
    plot(ax, NaN, NaN, ':', 'Color', style.muted, 'LineWidth', 1, ...
         'DisplayName', sprintf('Transmission radius (%g m)', env.CommRadius));   % legend entry

    % Routing: one segment from every node to its next hop.
    hops = [(1:env.NumNodes)', env.NextHop];
    link_x = [all_points(hops(:, 1), 1), all_points(hops(:, 2), 1), nan(env.NumNodes, 1)]';
    link_y = [all_points(hops(:, 1), 2), all_points(hops(:, 2), 2), nan(env.NumNodes, 1)]';
    plot(ax, link_x(:), link_y(:), '-', 'Color', style.gwo, 'LineWidth', 1.5, ...
         'DisplayName', 'Next-hop route');

    scatter(ax, positions(:, 1), positions(:, 2), 48, style.ink, 'filled', ...
            'MarkerEdgeColor', 'w', 'LineWidth', 1, 'DisplayName', 'Sensor node');
    scatter(ax, env.SinkPosition(1), env.SinkPosition(2), 140, style.random, 's', 'filled', ...
            'MarkerEdgeColor', 'w', 'LineWidth', 1.5, 'DisplayName', 'Sink');

    axis(ax, 'equal');
    margin = 0.04 * max(env.AreaSize);         % keeps edge nodes and the top tick clear
    xlim(ax, [-margin, env.AreaSize(1) + margin]);
    ylim(ax, [-margin, env.AreaSize(2) + margin]);
    styleAxes(ax);
    xlabel(ax, 'x (m)');
    ylabel(ax, 'y (m)');

    p = metrics.params;
    title(ax, 'Sensor network with GWO-tuned S-MAC');
    subtitle(ax, {sprintf('Duty %.1f%%  |  frame %.2f s  |  CW %d  |  SYNC every %d frames', ...
                          100 * p.duty_cycle, p.frame_length, p.contention_window, p.sync_period), ...
                  sprintf('PDR %.1f%%  |  delay %.2f s  |  power %.2f mW  |  lifetime %.0f days', ...
                          100 * metrics.pdr, metrics.mean_delay, 1e3 * metrics.mean_power, metrics.lifetime_days)}, ...
             'Color', style.ink, 'FontSize', 9);
    legend(ax, 'Location', 'southoutside', 'NumColumns', 2, 'Box', 'off');
end

function make_results_table(results, save_path)
%MAKE_RESULTS_TABLE  Render GWO-tuned vs. default S-MAC as a PNG table.
%
%   results = main();   % or simulate()
%   make_results_table(results)                 -> results/results_table.png  (run from the project root)
%   make_results_table(results, 'out.png')
%
%   Columns: GWO-tuned S-MAC, default S-MAC, random search (same budget).
%   Rows: the four tuned parameters, then the performance metrics.

    arguments
        results (1,1) struct
        save_path (1,1) string = fullfile("results", "results_table.png")
    end

    runs = {results.gwo.best_metrics, results.default.metrics, results.random_search.best_metrics};
    headers = {'', 'GWO-tuned S-MAC', 'Default S-MAC', 'Random search'};
    p = cellfun(@(m) m.params, runs, 'UniformOutput', false);
    p = [p{:}];

    % --- Rows: {label, values per run, which run is best (0 = none), is_section_title} ---
    % "best" is decided on the raw numbers; lower_is_better says in which direction.
    rows = {};
    rows(end+1, :) = {'S-MAC parameters', {'', '', ''}, 0, true};
    rows(end+1, :) = {'Duty cycle', arrayfun(@(q) sprintf('%.1f%%', 100 * q.duty_cycle), p, 'UniformOutput', false), 0, false};
    rows(end+1, :) = {'Frame length', arrayfun(@(q) sprintf('%.2f s', q.frame_length), p, 'UniformOutput', false), 0, false};
    rows(end+1, :) = {'Contention window', arrayfun(@(q) sprintf('%d slots', q.contention_window), p, 'UniformOutput', false), 0, false};
    rows(end+1, :) = {'SYNC period', arrayfun(@(q) sprintf('every %d frames', q.sync_period), p, 'UniformOutput', false), 0, false};

    metric_rows = {
        'Fitness (lower is better)', @(m) m.fitness,            '%.4f',        true
        'Packet delivery ratio',     @(m) 100 * m.pdr,          '%.1f%%',      false
        'Mean end-to-end delay',     @(m) m.mean_delay,         '%.2f s',      true
        'Mean node power',           @(m) 1e3 * m.mean_power,   '%.2f mW',     true
        'Network lifetime',          @(m) m.lifetime_days,      '%.0f days',   false
        'RTS collision rate',        @(m) 100 * m.collision_rate, '%.1f%%',    true
    };
    rows(end+1, :) = {'Performance', {'', '', ''}, 0, true};
    for r = 1:size(metric_rows, 1)
        values = cellfun(metric_rows{r, 2}, runs);
        if metric_rows{r, 4}
            [best_value, best] = min(values);
        else
            [best_value, best] = max(values);
        end
        if nnz(abs(values - best_value) < 1e-9) > 1
            best = 0;                               % tie: highlight nothing
        end
        labels = arrayfun(@(v) sprintf(metric_rows{r, 3}, v), values, 'UniformOutput', false);
        rows(end+1, :) = {metric_rows{r, 1}, labels, best, false}; %#ok<AGROW>
    end

    % --- Layout (data units = pixels at 1x) ---
    col_x = [24 290 480 670];           % left edge of each column
    width = 860;
    row_h = 40;
    top = 96;                           % y of the header row's top edge
    num_rows = size(rows, 1);
    height = top + row_h * (num_rows + 1) + 70;

    ink = [0.13 0.13 0.13];
    muted = [0.42 0.42 0.42];
    rule = [0.85 0.85 0.85];
    accent = [42 120 214] / 255;        % same blue as the GWO curve in simulate.m
    stripe = [0.965 0.965 0.965];
    font = 'Arial';

    fig = figure('Color', 'w', 'Visible', 'off', 'Units', 'pixels', 'Position', [100 100 width height]);
    ax = axes(fig, 'Position', [0 0 1 1], 'XLim', [0 width], 'YLim', [0 height], 'YDir', 'reverse');
    axis(ax, 'off');
    hold(ax, 'on');

    env = results.env;
    text(ax, col_x(1), 34, 'S-MAC tuned by the Grey Wolf Optimizer', ...
         'FontName', font, 'FontSize', 15, 'FontWeight', 'bold', 'Color', ink);
    text(ax, col_x(1), 62, sprintf(['%d sensor nodes, %g m %s %g m field, %d wolves %s %d iterations ' ...
         '(%d simulations), random search with the same budget'], env.NumNodes, env.AreaSize(1), ...
         char(215), env.AreaSize(2), results.options.NumWolves, char(215), ...
         results.options.MaxIterations, results.gwo.num_evaluations), ...
         'FontName', font, 'FontSize', 10, 'Color', muted);

    % Header row with an accent rule underneath.
    header_mid = top + row_h / 2;
    for c = 2:numel(headers)
        text(ax, col_x(c), header_mid, headers{c}, 'FontName', font, 'FontSize', 11, ...
             'FontWeight', 'bold', 'Color', ink, 'VerticalAlignment', 'middle');
    end
    plot(ax, [col_x(1) width - 24], [top + row_h top + row_h], '-', 'Color', accent, 'LineWidth', 2);

    % Body: section titles, zebra stripes, best value in bold.
    stripe_on = false;
    for r = 1:num_rows
        y0 = top + row_h * r;
        y_mid = y0 + row_h / 2;
        if rows{r, 4}
            text(ax, col_x(1), y_mid + 6, upper(rows{r, 1}), 'FontName', font, 'FontSize', 9, ...
                 'FontWeight', 'bold', 'Color', accent, 'VerticalAlignment', 'middle');
            stripe_on = false;
            continue;
        end
        if stripe_on
            patch(ax, [col_x(1) - 8, width - 24, width - 24, col_x(1) - 8], ...
                  [y0, y0, y0 + row_h, y0 + row_h], stripe, 'EdgeColor', 'none');
        end
        stripe_on = ~stripe_on;
        text(ax, col_x(1), y_mid, rows{r, 1}, 'FontName', font, 'FontSize', 11, 'Color', ink, ...
             'VerticalAlignment', 'middle');
        values = rows{r, 2};
        for c = 1:3
            weight = 'normal';
            if rows{r, 3} == c
                weight = 'bold';
            end
            text(ax, col_x(c + 1), y_mid, values{c}, 'FontName', font, 'FontSize', 11, ...
                 'Color', ink, 'FontWeight', weight, 'VerticalAlignment', 'middle');
        end
    end
    table_bottom = top + row_h * (num_rows + 1);
    plot(ax, [col_x(1) width - 24], [table_bottom table_bottom], '-', 'Color', rule, 'LineWidth', 1);

    w = results.mac.Weights;
    text(ax, col_x(1), table_bottom + 26, sprintf(['Fitness = %.1f %s energy + %.1f %s delay + %.1f %s (1 %s PDR). ' ...
         'Bold = best value in the row.'], w(1), char(183), w(2), char(183), w(3), char(183), char(8722)), ...
         'FontName', font, 'FontSize', 9.5, 'Color', muted);
    text(ax, col_x(1), table_bottom + 48, ['Single network and traffic seed; repeat over several ' ...
         'seeds before generalising.'], 'FontName', font, 'FontSize', 9.5, 'Color', muted);

    exportgraphics(fig, save_path, 'Resolution', 200, 'BackgroundColor', 'white', 'Padding', 24);
    close(fig);
    fprintf('Saved %s\n', save_path);
end

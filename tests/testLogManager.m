%TESTLOGMANAGER  Sanity checks for utils/LogManager. Run from the project root.

addpath(pwd, fullfile(pwd, 'utils'));

log_path = [tempname, '.log'];
file_id = fopen(log_path, 'w');
cleanup = onCleanup(@() delete(log_path));
columns = struct('name', {'Iteration', 'Best Fitness', 'Duty Cycle', 'Diversity'}, ...
                 'width', {9, 12, 10, 9}, 'format', {'%d', '%.6f', '%.1f%%', '%.4f'});

%% Test 1: header, rows and footer are written to the target file
logger = LogManager("Test run", columns, 'FileId', file_id, 'PrintEvery', 2);
logger.header();
logger.row({0, 0.5, 10, 0.3});
logger.row({1, 0.4, 12.5, 0.2});          % skipped by PrintEvery
logger.row({2, 0.25, 8.26, NaN});
logger.info('done after %d iterations', 2);
logger.footer();
fclose(file_id);
lines = splitlines(strtrim(fileread(log_path)));

assert(contains(lines{1}, '== Test run =='), 'Test 1 failed: title');
assert(any(contains(lines, 'Best Fitness')), 'Test 1 failed: column names');
rows = lines(startsWith(lines, '|') & ~contains(lines, 'Iteration'));
assert(numel(rows) == 2, 'Test 1 failed: PrintEvery should keep rows 1 and 3');
assert(contains(rows{2}, '0.250000') && contains(rows{2}, '8.3%'), 'Test 1 failed: row values');
assert(endsWith(strtrim(rows{2}), '- |'), 'Test 1 failed: NaN should print as -');
assert(any(contains(lines, 'INFO done after 2 iterations')), 'Test 1 failed: info line');

%% Test 2: every table line has the same width
table_lines = lines(startsWith(lines, '|') | startsWith(lines, '+'));
widths = cellfun(@numel, table_lines);
assert(all(widths == widths(1)), 'Test 2 failed: ragged table');

%% Test 3: a disabled logger prints nothing
quiet = LogManager("Quiet", columns, 'Enabled', false);
output = evalc('quiet.header(); quiet.row({1, 1, 1, 1}); quiet.footer();');
assert(isempty(output), 'Test 3 failed: disabled logger printed');

%% Test 4: a row with the wrong number of values is rejected
did_error = false;
try
    logger.row({1, 2});
catch err
    did_error = strcmp(err.identifier, 'LogManager:badRow');
end
assert(did_error, 'Test 4 failed: expected LogManager:badRow');

disp('All LogManager tests passed.');

%TESTLOGMANAGER  Sanity checks for utils/LogManager. Run from the project root.

addpath(pwd, fullfile(pwd, 'utils'));

log_path = [tempname, '.log'];
file_id = fopen(log_path, 'w');
cleanup = onCleanup(@() delete(log_path));

%% Test 1: header, rows and footer are written to the target file
logger = LogManager("Test run", 'FileId', file_id, 'PrintEvery', 2);
logger.header();
logger.iteration(1, 0.5, NaN, 0.3, 10);      % skipped by PrintEvery
logger.iteration(2, 0.25, 0.0123, 0.2, 20);
logger.info('done after %d iterations', 2);
logger.footer();
fclose(file_id);
lines = splitlines(strtrim(fileread(log_path)));

assert(contains(lines{1}, '== Test run =='), 'Test 1 failed: title');
assert(any(contains(lines, 'Best Alpha Fitness')), 'Test 1 failed: column names');
rows = lines(startsWith(lines, '|') & ~contains(lines, 'Iteration'));
assert(numel(rows) == 1, 'Test 1 failed: PrintEvery should skip odd iterations');
assert(contains(rows{1}, '0.250000') && contains(rows{1}, '0.01230'), 'Test 1 failed: row values');
assert(any(contains(lines, 'INFO done after 2 iterations')), 'Test 1 failed: info line');

%% Test 2: every table line has the same width
table_lines = lines(startsWith(lines, '|') | startsWith(lines, '+'));
widths = cellfun(@numel, table_lines);
assert(all(widths == widths(1)), 'Test 2 failed: ragged table');

%% Test 3: a disabled logger prints nothing
quiet = LogManager("Quiet", 'Enabled', false);
output = evalc('quiet.header(); quiet.iteration(1, 1, 1, 1, 1); quiet.footer();');
assert(isempty(output), 'Test 3 failed: disabled logger printed');

disp('All LogManager tests passed.');

% =========================================================================
% Script: full_complexity_loader.m
% Author: Terelle Cadd
% Date: 2025-08-06
%
% Description:
%   This script computes the weighted Sinha structural complexity of a
%   system-of-systems architecture using three components:
%
%   C1 - element complexity / criticality
%   C2 - weighted interface complexity
%   A  - filtered binary adjacency matrix showing which elements interact
%
%   The script loads:
%       1. The selected element list and interface counts from the DSM parser
%       2. C1 values from the criticality assessment spreadsheet
%       3. Interface weights from the C2 AHP/interface-weighting sheet
%       4. The original DSM matrix from the system architecture spreadsheet
%
%   It then filters the DSM to the active architecture elements, builds a
%   binary adjacency matrix, computes weighted C2 values, applies eta-based
%   weighting between C1 and C2, and calculates total weighted Sinha
%   complexity.
%
%   Total complexity formula used here:
%   Note: the individual C1 and C2 values associated are still scaled with
%   their associated eta value to balance C1 and C2 contributions
%
%       c = C1 + (C2 * C3 / n)
%
%   where:
%       C1 = sum of weighted element complexity values
%       C2 = sum of weighted interface complexity values
%       C3 = sum of singular value magnitudes of adjacency matrix A
%       n  = number of active architecture elements
% =========================================================================

%% === Load C2-selected element list from prior DSM parse ===

% Define the Excel file produced by the DSM parsing/export workflow.
% This file contains the active elements and counts of each interface type.
c2_file = 'DSM_Interface_Counts.xlsx';

% Read the C2/interface count file into a MATLAB table.
c2_data = readtable(c2_file);

% Extract the element names from the table and clean extra whitespace.
% These names define the active elements included in this complexity run.
elementNames = string(strtrim(c2_data.Element));

%% === Load C1 values from criticality assessment spreadsheet ===

% Define the spreadsheet containing the C1 criticality values and C2 weights.
c1_file = 'Wildfire Response Function Criticality.xlsx';

% Read the C1 summary sheet as raw cell data.
% readcell is used because this sheet may contain mixed text/numeric values.
rawC1 = readcell(c1_file, 'Sheet', 'C1 Summary');

% Extract element names from column A starting at row 3.
% The first two rows are assumed to contain headers or metadata.
rawNames = rawC1(3:end, 1);

% Loop through the raw names and sanitize blank, missing, or non-string cells.
for i = 1:length(rawNames)

    % Store the current raw cell value.
    val = rawNames{i};

    % Replace empty, NaN, or missing string values with an empty string.
    if isempty(val) || (isnumeric(val) && isnan(val)) || (isstring(val) && ismissing(val))
        rawNames{i} = "";

    % Convert any non-character and non-string value to a string.
    % This protects against numeric values accidentally appearing in the
    % element-name column.
    elseif ~ischar(val) && ~isstring(val)
        rawNames{i} = string(val);
    end
end

% Convert the cleaned raw names into a string array and trim whitespace.
allC1_names  = string(strtrim(string(rawNames)));

% Extract C1 values from the last column of the C1 summary sheet.
% This assumes the final column contains the final C1 value for each element.
allC1_values = rawC1(3:end, end);

% Match and filter C1 values to the included architecture elements.
% C1_results will store rows of {element name, C1 value}.
C1_results = {};

% Loop through each active element from the C2/interface-count file.
for i = 1:length(elementNames)

    % Find the matching element name in the C1 summary sheet.
    idx = find(allC1_names == elementNames(i));

    % If a matching numeric C1 value exists, store it.
    if ~isempty(idx) && isnumeric(allC1_values{idx})
        C1_results{i,1} = elementNames(i);
        C1_results{i,2} = allC1_values{idx};

    % Stop if any active element is missing a C1 value.
    % This prevents the final complexity calculation from silently using
    % incomplete data.
    else
        error("Missing C1 value for element: %s", elementNames(i));
    end
end

% Display matched C1 results for verification.
disp(C1_results)

%% === Load DSM and build filtered binary adjacency matrix A ===

% Load the full text-based DSM from the architecture spreadsheet.
% xlsread is used here to preserve mixed numeric/text DSM cell contents.
[~, ~, rawDSM] = xlsread('SOS DSM.xlsx', 'DSM');

% Extract DSM row headers, which contain source/row element names.
rowDSM_names = rawDSM(2:end, 1);

% Extract DSM column headers, which contain target/column element names.
colDSM_names = rawDSM(1, 2:end);

% Define a small cleanup function for DSM labels.
% char(160) removes non-breaking spaces that often appear after Excel copy/paste.
clean_string = @(x) strtrim(erase(string(x), char(160)));

% Clean row names, column names, and active element names so matching is
% not affected by whitespace or non-breaking spaces.
rowDSM_names = clean_string(rowDSM_names);
colDSM_names = clean_string(colDSM_names);
elementNames = clean_string(elementNames);

% Extract the DSM body by removing the row and column headers.
DSM_data_raw = rawDSM(2:end, 2:end);

% Find the row indices in the full DSM corresponding to the active elements.
[~, rowIdx] = ismember(elementNames, rowDSM_names);

% Find the column indices in the full DSM corresponding to the active elements.
[~, colIdx] = ismember(elementNames, colDSM_names);

% Identify active elements that were not found in the DSM row headers.
missingRows = elementNames(rowIdx == 0);

% Identify active elements that were not found in the DSM column headers.
missingCols = elementNames(colIdx == 0);

% Stop if any active element is missing from the DSM.
% This usually indicates a naming, spacing, or formatting mismatch.
if ~isempty(missingRows) || ~isempty(missingCols)
    disp("The following elements were not found in DSM row/column headers:");
    disp("Missing from rows:");
    disp(missingRows);
    disp("Missing from cols:");
    disp(missingCols);
    error("Element mismatch – check for name or formatting issues.");
end

% Determine the number of active elements in this filtered architecture.
n = length(elementNames);

% Initialize the filtered binary adjacency matrix.
% A(i,j) = 1 means element i has at least one interface with element j.
A = zeros(n, n);

% Loop through all active element pairs.
for i = 1:n
    for j = 1:n

        % Pull the original DSM cell corresponding to active element i,j.
        val = DSM_data_raw{rowIdx(i), colIdx(j)};

        % If the DSM cell contains any non-empty text, treat it as an
        % existing interface and set the binary adjacency value to 1.
        if ischar(val) && ~isempty(strtrim(val))
            A(i, j) = 1;
        end
    end
end

% Confirm the filtered adjacency matrix was created.
disp('Filtered adjacency matrix A created.');

%% === Compute Weighted C2 values ===

% List of DSM interface codes that should be included in the C2 calculation.
% These should match the interface-code columns in DSM_Interface_Counts.xlsx.
interface_codes = {'I','M','H','E','c','D','S','O','R','C','F','L','Y','X','P'};

% Load the interface weights from the C2 interface weight sheet.
% The range E11:F26 is expected to contain interface labels and weights.
weights_raw = readtable(c1_file, ...
    'Sheet', 'C2 Interface Weights', ...
    'Range', 'E11:F26', ...
    'ReadVariableNames', false);

% Create a structured table for interface type names and weights.
weights_table = table;

% Store full interface type names.
weights_table.InterfaceType = string(weights_raw{:,1});

% Store corresponding AHP-derived interface weights.
weights_table.Weight = weights_raw{:,2};

% Define mapping from DSM single-letter interface codes to full labels.
% This allows the script to connect compact DSM codes to the weight table.
code_to_label = containers.Map( ...
    {'M','H','E','I','c','D','O','S','R','C','F','L','X','Y','P'}, ...
    {'Mass','Physical','Energy','Information','Contribution','Development', ...
     'Operation','Service','Prerequisite','Coordination','Financial','Legal', ...
     'Contractual','Deliverable','Political'});

% Initialize the weighted C2 value for each active element.
% Each entry accumulates interface counts multiplied by interface weights.
totalComplexity = zeros(height(c2_data), 1);

% Loop through each interface code.
for i = 1:length(interface_codes)

    % Current single-letter DSM interface code.
    code = interface_codes{i};

    % Only process this code if the DSM count file contains a matching
    % column and the code is defined in the code-to-label map.
    if ismember(code, c2_data.Properties.VariableNames) && isKey(code_to_label, code)

        % Convert the code into the full interface label.
        label = code_to_label(code);

        % Find the corresponding interface weight in the weight table.
        weight_idx = strcmpi(weights_table.InterfaceType, label);

        % If a matching weight exists, add this interface contribution to C2.
        if any(weight_idx)

            % Extract the interface weight.
            weight = weights_table.Weight(weight_idx);

            % Weighted interface complexity contribution:
            %   interface count for each element times AHP-derived weight.
            totalComplexity = totalComplexity + c2_data.(code) .* weight;
        end
    end
end

% Display a summary of interface counts and weights.
% This is useful for checking that each DSM code maps to the expected
% interface type and that the correct weight is being applied.
disp('Weighted Interface Summary:');

% Loop through all interface codes again for reporting.
for i = 1:length(interface_codes)

    % Current single-letter DSM interface code.
    code = interface_codes{i};

    % Only report mapped codes that appear in the C2 count table.
    if ismember(code, c2_data.Properties.VariableNames) && isKey(code_to_label, code)

        % Convert code to full interface label.
        label = code_to_label(code);

        % Find this interface label in the weight table.
        weight_idx = strcmpi(weights_table.InterfaceType, label);

        % If a weight was found, print the code, label, weight, and total count.
        if any(weight_idx)
            fprintf('  %s (%s) → Weight: %.4f, Total Count: %g\n', ...
                code, label, weights_table.Weight(weight_idx), ...
                sum(c2_data.(code)));

        % If no weight was found, report that issue.
        else
            fprintf('  %s (%s) → Weight not found\n', code, label);
        end

    % If the code is not present in the count table or map, report it.
    else
        fprintf('  %s → Not found in DSM columns or code map\n', code);
    end
end

% Store C2 results as a two-column cell array:
%   column 1 = element name
%   column 2 = weighted interface complexity value
C2_results = [cellstr(c2_data.Element), num2cell(totalComplexity)];

% Confirm C2 calculation completed.
disp('Filtered C2 computed.');

%% === Final Sinha Complexity Calculation ===

% Extract numeric C1 values from the matched C1 results cell array.
C1_vec = cell2mat(C1_results(:,2));

% Extract raw C2 values from the C2 results cell array.
raw_C2_vals = C2_results(:,2);

% Clean the C2 values so NaNs or invalid entries become zero.
% validate_numeric is defined as a local helper function below.
clean_C2_vals = cellfun(@(x) validate_numeric(x), raw_C2_vals);

% Convert the cleaned C2 cell array into a numeric vector.
C2_vec = cell2mat(clean_C2_vals);

% Extract eta values from the interface count table.
% eta controls how each element balances C1 and C2 contributions.
expandedEta = c2_data.eta;

% Check that eta has the same length as the C1/C2 vectors.
if length(expandedEta) ~= length(C1_vec)
    error('eta_vec length does not match C1/C2 vectors');
end

% Apply eta weighting to C1.
% Elements with larger eta emphasize element complexity more heavily.
C1_vec = 2*expandedEta(:) .* C1_vec(:);

% Apply complementary eta weighting to C2.
% Elements with smaller eta emphasize interface complexity more heavily.
C2_vec = 2*(1 - expandedEta(:)) .* C2_vec(:);

% Verify C1, C2, and adjacency matrix dimensions are consistent.
% The number of C1/C2 entries must match the number of active elements in A.
if length(C1_vec) ~= length(C2_vec) || length(C1_vec) ~= size(A,1)
    error('Dimension mismatch between C1, C2, and A');
end

% Optional older/alternate lambda-estimation approach.
% This line is currently disabled and does not affect the calculation.
% lambda = estimate_lambda_from_pairs(C1_vec, C2_vec);

% Compute final weighted Sinha complexity using the helper function below.
total_complexity = get_weighted_sinha_complexity(A, C1_vec, C2_vec);

% Print the final complexity value.
fprintf('\nTotal Weighted Sinha Complexity (c): %.4f\n', total_complexity);

% -------------------------------------------------------------------------
% Local helper function: validate_numeric
% -------------------------------------------------------------------------
function out = validate_numeric(x)
%VALIDATE_NUMERIC
%
% Checks whether an input value is a valid scalar numeric value.
% If valid, the value is returned inside a cell. If invalid, the function
% returns zero inside a cell.
%
% This is used to safely clean C2 values before converting them to a numeric
% vector.

    % If x is numeric, scalar, and not NaN, keep it.
    if isnumeric(x) && isscalar(x) && ~isnan(x)
        out = {x};

    % Otherwise, replace missing or invalid values with zero.
    else
        out = {0};
    end
end

% -------------------------------------------------------------------------
% Local helper function: get_weighted_sinha_complexity
% -------------------------------------------------------------------------
function c = get_weighted_sinha_complexity(A, C1_vec, C2_mat)
%GET_WEIGHTED_SINHA_COMPLEXITY
%
% Computes weighted Sinha structural complexity using:
%
%   c = C1 + (C2 * C3 / n)
%
% where:
%   C1 = sum of weighted element complexity values
%   C2 = sum of weighted interface complexity values
%   C3 = topological complexity term from the adjacency matrix
%   n  = number of elements
%
% Reference:
%   Sinha, K., and Suh, E. S. "Pareto-optimization of complex system
%   architecture for structural complexity and modularity."
%   Research in Engineering Design, 29, 123-141, 2018.
%   https://doi.org/10.1007/s00163-017-0260-9

% Number of active elements in the filtered adjacency matrix.
n = length(A(:, 1))

% Sum weighted C1 values across all active elements.
C1 = sum(C1_vec)

% Sum weighted C2 values across all active elements.
C2 = sum(C2_mat, "all")

% Compute the topological complexity term.
% svd(A) returns singular values of the binary adjacency matrix.
% The sum of absolute singular values is used here as the C3 metric.
C3 = sum(abs(svd(A)))

% Combine C1, C2, and C3 into total weighted complexity.
c = C1 + C2 * C3 / n;

end
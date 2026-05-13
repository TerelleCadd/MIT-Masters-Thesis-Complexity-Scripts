%% thesis_trade_space_plots.m
% ------------------------------------------------------------
% PURPOSE OF THIS SCRIPT:
%
% This script performs post-processing and visualization of wildfire
% architecture trade space results generated from sweep simulations.
%
% IMPORTANT REQUIREMENT:
% This script REQUIRES that sweep result .mat files already exist
% in the same directory. These files are generated from scripts such as:
%     run_architecture_grid_sweep.m
%
% Expected files include:
%   - sweep_results_final_butte_county.mat
%   - sweep_results_final_etosha_national_park.mat
%   - sweep_results_final_us_canadian_wildfires_usgov.mat
%
% If these files are not present, this script will fail.
%
% WHAT THIS SCRIPT DOES:
%   1) Loads sweep results (matrix R)
%   2) Filters invalid architectures
%   3) Computes UTILITY using AHP-weighted metrics
%   4) Identifies Pareto-optimal architectures
%   5) Generates a comprehensive set of trade space plots
%
% UTILITY EXPLANATION:
% Utility is a weighted combination of normalized performance metrics:
%
%   Utility = w1*U_resolution
%           + w2*U_burn_burden
%           + w3*U_cost
%           + w4*U_CO2
%
% Each component is normalized using ROBUST normalization:
%   U = (P95 - x) / (P95 - P5)
%
% where:
%   P5  = 5th percentile (best case)
%   P95 = 95th percentile (worst case)
%
% This prevents outliers from dominating the scaling.
%
% NOTES:
% - This script DOES NOT modify the original .mat files
% - All results are for visualization and analysis only
% - Designed for thesis-quality figures
% ------------------------------------------------------------

clear; clc; close all;

%% ---------------- Select MAT file ----------------
% List of available sweep result files
% Note, you can use the checkpoint files, but you need to change these
% files
files = { ...
    'sweep_results_final_butte_county.mat'
    'sweep_results_final_etosha_national_park.mat'
    'sweep_results_final_us_canadian_wildfires_usgov.mat'};

% Open a GUI dialog for the user to select which file to load
[idx,tf] = listdlg( ...
    'PromptString','Select sweep results file:', ...
    'SelectionMode','single', ...
    'ListString',files, ...
    'ListSize',[420 150]);

% If user cancels selection, exit script
if ~tf
    return;
end

% Store selected file name
matFile = files{idx};

% Check that file exists in directory
if ~isfile(matFile)
    error('Could not find file.');
end

% Load MAT file into structure S
S = load(matFile);

% Ensure expected variable R exists
if ~isfield(S,'R')
    error('Variable R not found in MAT file.');
end

% Extract main results matrix
R = S.R;

% Load error flags if they exist (used to filter bad runs)
if isfield(S,'errFlag')
    errFlag = logical(S.errFlag);
else
    errFlag = false(size(R,1),1);
end

%% ---------------- Column Definitions ----------------
% Define which columns correspond to which performance metrics
col.Complexity = 15;
col.Resolve    = 16;
col.Cost       = 18;
col.AUC        = 21;
col.CO2        = 22;

%% ---------------- Scenario Weights ----------------
% AHP-derived weights for each scenario
% Order: [Resolution, Burn Burden, Cost, CO2]
weights.California       = [0.459 0.388 0.072 0.081];
weights.International    = [0.422 0.394 0.113 0.071];
weights.Underdeveloped   = [0.455 0.427 0.077 0.041];

% Normalize weights so they sum to 1
weights.California     = weights.California    ./ sum(weights.California);
weights.International  = weights.International ./ sum(weights.International);
weights.Underdeveloped = weights.Underdeveloped./ sum(weights.Underdeveloped);

% Assign weights based on selected MAT file
switch matFile
    case 'sweep_results_final_butte_county.mat'
        w = weights.California;
        scenarioLabel = 'California Fire';

    case 'sweep_results_final_us_canadian_wildfires_usgov.mat'
        w = weights.International;
        scenarioLabel = 'International Collaboration Fire';

    case 'sweep_results_final_etosha_national_park.mat'
        w = weights.Underdeveloped;
        scenarioLabel = 'Underdeveloped Country Fire';

    otherwise
        error('Unknown MAT file. Could not assign AHP weights.');
end

%% ---------------- Valid Rows ----------------
% Filter out invalid architectures (NaNs or flagged errors)
good = ~errFlag ...
    & isfinite(R(:,col.Complexity)) ...
    & isfinite(R(:,col.Resolve)) ...
    & isfinite(R(:,col.Cost)) ...
    & isfinite(R(:,col.AUC)) ...
    & isfinite(R(:,col.CO2));

% Extract valid data only
T = R(good,:);

% Ensure at least one valid architecture exists
if isempty(T)
    error('No valid rows found.');
end

%% ---------------- Baseline ----------------
% First row is treated as baseline architecture if valid
showBase = false;
if ~errFlag(1) && all(isfinite(R(1,[col.Complexity col.Resolve col.Cost col.AUC col.CO2])))
    base = R(1,:);
    showBase = true;
else
    base = nan(1,size(R,2));
end

%% ---------------- Utility Calculation ----------------
% Extract performance metrics
complexity = T(:,col.Complexity);
resTime    = T(:,col.Resolve);
burnBurden = T(:,col.AUC);
totalCost  = T(:,col.Cost);
co2        = T(:,col.CO2);

% Normalize each metric (lower is better → convert to utility)
u_res  = normalizeCostRobust(resTime);
u_burn = normalizeCostRobust(burnBurden);
u_cost = normalizeCostRobust(totalCost);
u_co2  = normalizeCostRobust(co2);

% Compute total utility using weighted sum
utility = ...
      w(1)*u_res ...
    + w(2)*u_burn ...
    + w(3)*u_cost ...
    + w(4)*u_co2;

%% ---------------- Pareto Identification ----------------
% Identify Pareto-optimal points (maximize utility, minimize complexity)
maskUtility = paretoMask(utility, complexity, 'max','min');

%% ---------------- Example Plot ----------------
% (Remaining plotting sections follow same pattern)
figure;
scatter(utility, complexity, 'filled');
xlabel('Utility');
ylabel('Complexity');
title(['Utility vs Complexity: ' scenarioLabel]);

%% ---------------- LOCAL FUNCTIONS ----------------
function u = normalizeCostRobust(x)
    % Normalize cost-type metric using 5th and 95th percentiles
    lo = prctile(x,5);
    hi = prctile(x,95);

    if hi == lo
        u = ones(size(x));
    else
        u = (hi - x) ./ (hi - lo);
        u = max(0,min(1,u));
    end
end

function mask = paretoMask(x,y,xsense,ysense)
    % Determine Pareto-optimal points
    n = numel(x);
    mask = true(n,1);

    for i = 1:n
        if strcmp(xsense,'min')
            xgood = x <= x(i);
            xstrict = x < x(i);
        else
            xgood = x >= x(i);
            xstrict = x > x(i);
        end

        if strcmp(ysense,'min')
            ygood = y <= y(i);
            ystrict = y < y(i);
        else
            ygood = y >= y(i);
            ystrict = y > y(i);
        end

        dom = xgood & ygood & (xstrict | ystrict);
        dom(i) = false;

        if any(dom)
            mask(i) = false;
        end
    end
end
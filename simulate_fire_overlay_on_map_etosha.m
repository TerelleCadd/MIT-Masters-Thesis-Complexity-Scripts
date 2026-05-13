function out = simulate_fire_overlay_on_map_etosha(I_map, latGrid, lonGrid, latPoly, lonPoly, ignLat, ignLon, daysTotal, opts)
%SIMULATE_FIRE_OVERLAY_ON_MAP_ETOSHA
%
% This function simulates wildfire spread for the Etosha scenario using a
% deterministic spread-field model constrained to a known final perimeter.
%
% The fire starts from a specified ignition point, spreads through a spatial
% cost field, and is scaled so that the simulated final burn mask matches
% the extracted perimeter polygon at day = daysTotal.
%
% The model also produces:
%   - burn masks over time
%   - burned area history in acres
%   - deterministic spread-field heatmap
%   - deterministic spread-field contour plot
%   - burn area versus time plot
%   - fire spread animation overlay
%   - optional GIF export
%
% Outputs:
%   out.maskAtTime          - burn masks over time
%   out.tHours              - time vector [hours]
%   out.areaAcresMask       - area history from mask [acres]
%   out.targetAcres         - final target mask area [acres]
%   out.ignPixRequested     - requested ignition pixel [x y]
%   out.ignPixUsed          - actual ignition pixel used [x y]
%   out.ignLatLonRequested  - requested ignition lat/lon [lat lon]
%   out.ignLatLonUsed       - actual ignition lat/lon [lat lon]
%   out.targetMask          - rasterized final perimeter mask
%   out.T                   - travel distance field
%   out.mpp                 - meters per pixel
%   out.areaAcres           - alias of areaAcresMask

% If no options structure is provided, create an empty one.
% The defaults below will then be assigned automatically.
if nargin < 9
    opts = struct();
end

% -------------------- Defaults --------------------
% These default values define the baseline behavior of the Etosha fire
% spread model unless the user overrides them through opts.

% Wind direction in degrees using meteorological convention.
% This is the direction the wind comes FROM.
if ~isfield(opts,'windDirFromDeg'),       opts.windDirFromDeg = 225; end

% Controls how strongly the fire prefers to spread downwind.
% A value of 1 would remove wind-direction preference.
if ~isfield(opts,'anisotropy'),           opts.anisotropy = 2.0; end

% Time spacing between saved simulation frames, in hours.
if ~isfield(opts,'frameStepHours'),       opts.frameStepHours = 6; end

% Transparency of the red burn overlay in the animation.
if ~isfield(opts,'alpha'),                opts.alpha = 0.35; end

% Enables use of image-based moisture/dryness proxy.
if ~isfield(opts,'useMoisture'),          opts.useMoisture = true; end

% Enables optional elevation/slope effects.
if ~isfield(opts,'useElevation'),         opts.useElevation = false; end

% Weight applied to the image-derived wetness field.
% Higher values make wetter-looking regions more resistant to spread.
if ~isfield(opts,'moistureWeight'),       opts.moistureWeight = 1.5; end

% Weight applied to slope effects if elevation is enabled.
if ~isfield(opts,'slopeWeight'),          opts.slopeWeight = 2.0; end

% Elevation grid used only if opts.useElevation is true.
if ~isfield(opts,'elevGrid'),             opts.elevGrid = []; end

% Optional visual patchiness for the burn mask.
% A value of zero keeps the burn mask fully deterministic.
if ~isfield(opts,'patchiness'),           opts.patchiness = 0; end

% If true, an ignition point outside the final perimeter is moved to the
% nearest valid pixel inside the target mask.
if ~isfield(opts,'snapIgnitionToTarget'), opts.snapIgnitionToTarget = true; end

% Controls whether ignition markers are shown on figures.
if ~isfield(opts,'showIgnitionMarker'),   opts.showIgnitionMarker = true; end

% Controls whether the fire animation is saved as a GIF.
if ~isfield(opts,'saveGif'),              opts.saveGif = false; end

% Default output filename for the optional GIF.
if ~isfield(opts,'gifFile'),              opts.gifFile = 'etosha_fire_animation.gif'; end

% Delay between GIF frames, in seconds.
if ~isfield(opts,'gifDelayTime'),         opts.gifDelayTime = 0.20; end

% Optional manual override for ignition pixel location.
% If provided, this overrides ignLat and ignLon.
if ~isfield(opts,'ignPixOverride'),       opts.ignPixOverride = []; end

% Toggle for deterministic spread-field heatmap.
if ~isfield(opts,'makeTfieldHeatmap'),    opts.makeTfieldHeatmap = true; end

% Toggle for deterministic spread-field contour plot.
if ~isfield(opts,'makeTfieldContours'),   opts.makeTfieldContours = true; end

% Transparency for deterministic spread-field heatmap overlay.
if ~isfield(opts,'tfieldAlpha'),          opts.tfieldAlpha = 0.45; end

% Number of contour levels used in the deterministic spread-field plot.
if ~isfield(opts,'nContourLevels'),       opts.nContourLevels = 6; end

% If no spread-rate schedule is provided, use an Etosha-specific profile.
% Each row has the form [end time in hours, spread speed in meters/second].
if ~isfield(opts,'rateSchedule')
    % Etosha-specific inferred growth profile:
    %   - very fast first 1-2 days
    %   - still strong through day ~4
    %   - slower expansion after that
    %   - low-speed fill-in by perimeter date
    opts.rateSchedule = [
        12,             2.6;
        24,             1.9;
        48,             1.4;
        72,             1.0;
        120,            0.45;
        24*daysTotal,   0.12
    ];
end

% Store image height and width.
H = size(I_map,1);
W = size(I_map,2);

% Print ignition information for debugging.
% This helps confirm whether the requested ignition location is landing
% where expected on the map.
fprintf('\n--- DEBUG IGNITION INPUTS ---\n');
fprintf('Input ignLat = %.6f, ignLon = %.6f\n', ignLat, ignLon);

% Print the ignition pixel override if one was provided.
if isfield(opts,'ignPixOverride') && ~isempty(opts.ignPixOverride)
    fprintf('opts.ignPixOverride = [%.1f, %.1f]\n', ...
        opts.ignPixOverride(1), opts.ignPixOverride(2));
else
    fprintf('opts.ignPixOverride is empty\n');
end

% -------------------- Rasterize target perimeter --------------------
% Convert the final perimeter polygon from latitude/longitude coordinates
% into image pixel coordinates.
[xPoly, yPoly] = latlon_to_pixel(latPoly, lonPoly, latGrid, lonGrid);

% Convert the polygon into a binary image mask.
% Pixels inside the extracted perimeter are true.
targetMask = poly2mask(xPoly, yPoly, H, W);

% Stop the function if the perimeter could not be converted into a valid
% mask. This usually means the polygon and map grid are not aligned.
if ~any(targetMask(:))
    error('Target perimeter rasterized to an empty mask.');
end

% -------------------- Requested ignition pixel --------------------
% Determine the requested ignition pixel. If the user provides a manual
% pixel override, use that. Otherwise, convert the ignition lat/lon.
if ~isempty(opts.ignPixOverride) && numel(opts.ignPixOverride) == 2

    % Use the manually specified ignition pixel.
    xIgnReq = round(opts.ignPixOverride(1));
    yIgnReq = round(opts.ignPixOverride(2));
else

    % Convert ignition latitude/longitude to pixel coordinates.
    [xIgnReq, yIgnReq] = latlon_to_pixel(ignLat, ignLon, latGrid, lonGrid);

    % Round to integer pixel indices.
    xIgnReq = round(xIgnReq);
    yIgnReq = round(yIgnReq);
end

% Keep requested ignition pixel inside valid image bounds.
% The value is kept away from the outermost boundary to avoid neighbor
% indexing problems in the spread calculation.
xIgnReq = max(2, min(W-1, xIgnReq));
yIgnReq = max(2, min(H-1, yIgnReq));

% Store the latitude/longitude corresponding to the requested ignition
% pixel after rounding and bounds checking.
reqLat = latGrid(yIgnReq, xIgnReq);
reqLon = lonGrid(yIgnReq, xIgnReq);

% Initialize the actual ignition pixel as the requested ignition pixel.
% It may be adjusted below if the point lies outside the final perimeter.
xIgn = xIgnReq;
yIgn = yIgnReq;

% Print the requested and initially used ignition pixels.
fprintf('Requested ignition pixel: (%d,%d)\n', xIgnReq, yIgnReq);
fprintf('Used ignition pixel: (%d,%d)\n', xIgn, yIgn);

% If the requested ignition is outside the final perimeter, snap it to the
% nearest pixel that lies inside the target mask.
if opts.snapIgnitionToTarget && ~targetMask(yIgn, xIgn)

    % Find all valid target-mask pixel coordinates.
    [yyT, xxT] = find(targetMask);

    % Compute squared distance from requested ignition to each valid pixel.
    d2 = (double(xxT) - double(xIgn)).^2 + (double(yyT) - double(yIgn)).^2;

    % Identify the nearest valid target-mask pixel.
    [~, iMin] = min(d2);

    % Use that nearest valid pixel as the actual ignition location.
    xIgn = xxT(iMin);
    yIgn = yyT(iMin);

    % Print debugging information about the snap.
    fprintf('Requested ignition pixel (%d,%d) was outside target mask.\n', xIgnReq, yIgnReq);
    fprintf('Snapped ignition to nearest target pixel (%d,%d).\n', xIgn, yIgn);
else

    % If the requested ignition point was already valid, keep it.
    fprintf('Ignition pixel inside target mask: (%d,%d)\n', xIgn, yIgn);
end

% Store the latitude/longitude corresponding to the actual ignition pixel.
useLat = latGrid(yIgn, xIgn);
useLon = lonGrid(yIgn, xIgn);

% Print requested and actual ignition coordinates for verification.
fprintf('Requested ignition lat/lon: %.6f, %.6f\n', reqLat, reqLon);
fprintf('Actual used ignition lat/lon: %.6f, %.6f\n', useLat, useLon);

% -------------------- meters per pixel --------------------
% Estimate physical pixel spacing near the ignition location using the
% latitude/longitude grid.

% Estimate horizontal pixel spacing in meters.
dx_m = local_meters_between( ...
    latGrid(yIgn,xIgn), lonGrid(yIgn,xIgn), ...
    latGrid(yIgn,xIgn), lonGrid(yIgn,min(W,xIgn+1)));

% Estimate vertical pixel spacing in meters.
dy_m = local_meters_between( ...
    latGrid(yIgn,xIgn), lonGrid(yIgn,xIgn), ...
    latGrid(min(H,yIgn+1),xIgn), lonGrid(min(H,yIgn+1),xIgn));

% Use the average of horizontal and vertical spacing as meters per pixel.
mpp = mean([dx_m, dy_m]);

% Stop if meters-per-pixel could not be estimated.
if ~isfinite(mpp) || mpp <= 0
    error('Could not estimate meters-per-pixel from lat/lon grids.');
end

% Convert one pixel area into acres.
% mpp^2 gives square meters per pixel.
acrePerPixel = (mpp^2) * 0.000247105381;

% -------------------- Moisture/dryness proxy cost --------------------
% Initialize the spread cost field as neutral everywhere.
% Values above 1 slow spread. Values below 1 speed spread.
moistCost = ones(H,W);

% If enabled, derive a rough moisture/wetness cost field from the map image.
if opts.useMoisture

    % Convert map image to grayscale double precision.
    Ig = im2double(im2gray(I_map));

    % Smooth the grayscale map to capture broad brightness trends.
    Ig_blur  = imgaussfilt(Ig, 6);

    % Treat darker smoothed regions as wetter or more resistant.
    wet_dark = 1 - mat2gray(Ig_blur);

    % Compute image gradients to estimate local texture.
    [Gx, Gy] = imgradientxy(Ig);

    % Combine x and y gradients into total gradient magnitude.
    gradmag = hypot(Gx, Gy);

    % Smooth and normalize the gradient magnitude to create a ruggedness
    % proxy.
    rugged  = mat2gray(imgaussfilt(gradmag, 2));

    % Combine darkness and smoothness into a simplified wetness proxy.
    wetness = 0.70*wet_dark + 0.30*(1 - rugged);

    % Clamp wetness values between 0 and 1.
    wetness = min(max(wetness,0),1);

    % Convert wetness into multiplicative spread cost.
    moistCost = exp(opts.moistureWeight * wetness);

    % Clamp cost values to avoid unrealistic extremes.
    moistCost = min(max(moistCost, 0.6), 3.0);
end

% -------------------- Elevation (optional) --------------------
% Initialize elevation as empty.
elev = [];

% If elevation effects are enabled, validate and resize the elevation grid.
if opts.useElevation

    % Retrieve elevation grid from the options structure.
    elev = opts.elevGrid;

    % If no elevation grid was supplied, disable elevation effects.
    if isempty(elev)
        warning('opts.useElevation=true but opts.elevGrid empty. Disabling elevation effect.');
        opts.useElevation = false;
    else

        % Resize elevation grid if it does not match the map dimensions.
        if ~isequal(size(elev,1),H) || ~isequal(size(elev,2),W)
            elev = imresize(elev, [H W], 'bilinear');
        end
    end
end

% -------------------- Wind unit vector in image coords --------------------
% Convert meteorological wind direction FROM into propagation direction TO.
dirTo = mod(opts.windDirFromDeg + 180, 360);

% Convert direction angle into x/y image-coordinate components.
% +x points right/east and +y points down/south.
wx = sind(dirTo);
wy = -cosd(dirTo);

% Normalize the wind vector.
wn = hypot(wx, wy);
wx = wx / max(wn, 1e-12);
wy = wy / max(wn, 1e-12);

% -------------------- Travel distance field --------------------
% Compute the deterministic spread field using Dijkstra's algorithm.
% Lower Tfield values indicate pixels that are easier or earlier to reach.
Tfield = dijkstra_travel_time(moistCost, xIgn, yIgn, mpp, wx, wy, opts.anisotropy, elev, opts);

% -------------------- Time grid --------------------
% Convert total simulation duration from days to hours.
Tend_hours = daysTotal * 24;

% Create time vector for saved frames.
tHours = 0:opts.frameStepHours:Tend_hours;

% Ensure the final simulation time is included.
if isempty(tHours) || tHours(end) < Tend_hours
    tHours(end+1) = Tend_hours;
end

% Ensure the rate schedule covers the full simulation horizon.
% If it does not, append a final row using the last available spread rate.
if opts.rateSchedule(end,1) < Tend_hours
    opts.rateSchedule(end+1,:) = [Tend_hours, opts.rateSchedule(end,2)];
end

% -------------------- Scale distance budget to fill perimeter at end --------------------
% Extract travel-field values inside the target perimeter.
Tin = Tfield(targetMask);

% Keep only finite travel-field values.
Tin = Tin(isfinite(Tin));

% Stop if the target mask does not contain any reachable values.
if isempty(Tin)
    error('No finite travel-time values inside target mask.');
end

% The maximum travel-field value inside the perimeter is the amount needed
% to fill the final perimeter.
tauEndNeeded = max(Tin);

% Compute cumulative spread distance from the rate schedule at each time.
DmBase = cumulative_distance_budget(tHours, opts.rateSchedule);

% Scale the distance budget so the model reaches the full target perimeter
% at the final simulation time.
scale = tauEndNeeded / max(DmBase(end), 1e-9);
DmBase = DmBase * scale;

% -------------------- Allocate outputs --------------------
% Allocate cell array for burn masks at each time step.
maskAtTime    = cell(numel(tHours),1);

% Allocate burned-area history vector.
areaAcresMask = zeros(numel(tHours),1);

% -------------------- Simulate constrained growth --------------------
% Loop through each time and determine which pixels have burned.
for i = 1:numel(tHours)

    % Core deterministic burn mask.
    % A pixel burns if its travel-field value is less than the current
    % scaled distance budget and it lies inside the final target perimeter.
    maskCore = (Tfield <= DmBase(i)) & targetMask;

    % Start with the deterministic core mask.
    mask = maskCore;

    % Optional patchiness adds visual irregularity to the burn mask.
    % This does not change the underlying deterministic spread field.
    if opts.patchiness > 0

        % Convert moisture cost to burn-display probability.
        pBurn = exp(-opts.patchiness * (moistCost - 1));

        % Clamp probabilities to a reasonable range.
        pBurn = min(max(pBurn, 0.05), 1.0);

        % Randomly thin the mask based on the burn probability.
        mask = mask & (rand(size(mask)) < pBurn);

        % Remove small isolated pixels.
        mask = imopen(mask, strel('disk', 1));

        % Fill small gaps in the displayed mask.
        mask = imclose(mask, strel('disk', 2));
    end

    % Store the mask for the current time.
    maskAtTime{i} = mask;

    % Convert burned pixels to acres.
    areaAcresMask(i) = nnz(mask) * acrePerPixel;
end

% Compute final target area from the target perimeter mask.
targetAcres = nnz(targetMask) * acrePerPixel;

% -------------------- Outputs --------------------
% Store burn masks over time.
out.maskAtTime         = maskAtTime;

% Store time vector in hours.
out.tHours             = tHours;

% Store burn area history in acres.
out.areaAcresMask      = areaAcresMask;

% Store final target area in acres.
out.targetAcres        = targetAcres;

% Store requested ignition pixel.
out.ignPixRequested    = [xIgnReq yIgnReq];

% Store actual ignition pixel used.
out.ignPixUsed         = [xIgn yIgn];

% Store requested ignition latitude/longitude.
out.ignLatLonRequested = [reqLat reqLon];

% Store actual ignition latitude/longitude used.
out.ignLatLonUsed      = [useLat useLon];

% Store final perimeter mask.
out.targetMask         = targetMask;

% Store deterministic spread field.
out.T                  = Tfield;

% Store meters-per-pixel estimate.
out.mpp                = mpp;

% Store alias for burn area history.
out.areaAcres          = areaAcresMask;

% -------------------- Intermediate deterministic spread-field visualizations --------------------
% Create a copy of the spread field for visualization.
Tvis = Tfield;

% Hide values outside the final target perimeter.
Tvis(~targetMask) = NaN;

% Extract finite values inside the target perimeter.
finiteT = Tvis(isfinite(Tvis));

% Only create spread-field visualizations if valid values exist.
if ~isempty(finiteT)

    % Normalize the spread field between 0 and 1 for plotting.
    Tnorm = (Tvis - min(finiteT)) ./ max(max(finiteT) - min(finiteT), eps);

    % Create deterministic spread-field heatmap if enabled.
    if opts.makeTfieldHeatmap

        % Create heatmap figure.
        figT = figure('Name','Etosha Deterministic Spread Field Heatmap','Color','w');

        % Create axes in the figure.
        axT = axes(figT); %#ok<LAXES>

        % Display original map image as the background.
        imshow(I_map, 'Parent', axT);
        hold(axT,'on');

        % Overlay normalized deterministic spread field.
        hT = imagesc(axT, Tnorm);

        % Apply transparency so the background map remains visible.
        % Only show the overlay inside the target perimeter.
        set(hT, 'AlphaData', opts.tfieldAlpha * double(targetMask & isfinite(Tnorm)));

        % Use high-contrast colormap.
        colormap(axT, turbo);

        % Add colorbar for normalized arrival metric.
        cb = colorbar(axT);
        cb.Label.String = 'Normalized Deterministic Arrival Metric';
        cb.Label.Interpreter = 'latex';
        cb.TickLabelInterpreter = 'latex';

        % Plot final perimeter outline.
        plot(axT, xPoly, yPoly, '-', 'Color', [1 0.9 0], 'LineWidth', 2.0);

        % If enabled, plot requested ignition point.
        if opts.showIgnitionMarker
            plot(axT, xIgnReq, yIgnReq, 'co', 'MarkerSize', 10, 'LineWidth', 2);
        end

        % Plot actual ignition point used by the model.
        plot(axT, xIgn, yIgn, 'wo', ...
            'MarkerFaceColor', [0.85 0.1 0.1], ...
            'MarkerEdgeColor', 'k', ...
            'MarkerSize', 8);

        % Add title.
        title(axT, 'Deterministic Spread Field $T(\mathbf{x})$', ...
            'Interpreter','latex', 'FontSize', 16);

        % Apply consistent axis formatting.
        set(axT, 'FontName', 'Times', 'FontSize', 12, ...
            'TickLabelInterpreter','latex', 'LineWidth', 1.0);
    end

    % Create deterministic spread-field contour plot if enabled.
    if opts.makeTfieldContours

        % Create contour figure.
        figC = figure('Name','Etosha Deterministic Spread Field Contours','Color','w');

        % Create axes in the figure.
        axC = axes(figC); %#ok<LAXES>

        % Display original map image as the background.
        imshow(I_map, 'Parent', axC);
        hold(axC,'on');

        % Add faint normalized spread-field background.
        hBase = imagesc(axC, Tnorm);

        % Make background overlay transparent and limited to the target mask.
        set(hBase, 'AlphaData', 0.18 * double(targetMask & isfinite(Tnorm)));

        % Use parula colormap for the faint background.
        colormap(axC, parula);

        % Copy the travel field for contour plotting.
        Tcont = Tfield;

        % Hide values outside the final perimeter.
        Tcont(~targetMask) = NaN;

        % Define contour levels inside the min/max travel-field range.
        tLevels = linspace(min(finiteT), max(finiteT), opts.nContourLevels + 2);

        % Remove the extreme levels so the contour plot is easier to read.
        tLevels = tLevels(2:end-1);

        % Draw contour lines.
        [C,hContour] = contour(axC, Tcont, tLevels, ...
            'LineColor', 'w', 'LineWidth', 1.4);

        % Add contour labels.
        clabel(C, hContour, 'Color', 'w', 'FontSize', 9, ...
            'Interpreter', 'latex', 'LabelSpacing', 350);

        % Plot final perimeter outline.
        plot(axC, xPoly, yPoly, '-', 'Color', [1 0.9 0], 'LineWidth', 2.0);

        % If enabled, plot requested ignition point.
        if opts.showIgnitionMarker
            plot(axC, xIgnReq, yIgnReq, 'co', 'MarkerSize', 10, 'LineWidth', 2);
        end

        % Plot actual ignition point used by the model.
        plot(axC, xIgn, yIgn, 'wo', ...
            'MarkerFaceColor', [0.85 0.1 0.1], ...
            'MarkerEdgeColor', 'k', ...
            'MarkerSize', 8);

        % Add title.
        title(axC, 'Contours of Deterministic Spread Field', ...
            'Interpreter','latex', 'FontSize', 16);

        % Apply consistent axis formatting.
        set(axC, 'FontName', 'Times', 'FontSize', 12, ...
            'TickLabelInterpreter','latex', 'LineWidth', 1.0);
    end
end

% -------------------- Burn area plot --------------------
% Create figure showing burned area over time.
figure('Name','Etosha Burn Area vs. Time','Color','w');

% Plot burn area against simulation time in days.
plot(tHours/24, areaAcresMask, 'LineWidth', 2.5);

% Add grid and plot box for readability.
grid on;
box on;

% Label x-axis.
xlabel('Time [Days]','FontSize',12);

% Label y-axis.
ylabel('Burn Area [Acres]','FontSize',12);

% Add title.
title('Etosha Burn Area vs. Time', 'FontSize', 13);

% Add vertical marker at the final perimeter-matching day.
xline(daysTotal, '--k', sprintf('Day %.1f (perimeter match)', daysTotal), ...
    'LabelVerticalAlignment','bottom', ...
    'LabelHorizontalAlignment','left');

% Add horizontal marker at final target area.
yline(targetAcres, '--', 'Target final acres', ...
    'LabelHorizontalAlignment','left');

% Set x-axis limits from zero to final simulation day.
xlim([0 max(tHours)/24]);

% Set y-axis slightly above maximum burned area.
ylim([0 1.05*max(areaAcresMask)]);

% Set axis font size.
set(gca,'FontSize',11);

% -------------------- Animation overlay --------------------
% Create figure for fire spread animation.
figAnim = figure('Name','Etosha Fire Spread (Animation - maskAtTime)','Color','w');

% Create axes for animation.
ax = axes(figAnim); %#ok<LAXES>

% Display original map image as background.
imshow(I_map, 'Parent', ax);
hold(ax, 'on');

% Plot final perimeter outline.
plot(ax, xPoly, yPoly, 'y-', 'LineWidth', 2);

% Optionally show ignition markers.
if opts.showIgnitionMarker

    % Cyan circle marks requested ignition point.
    plot(ax, xIgnReq, yIgnReq, 'co', 'MarkerSize', 10, 'LineWidth', 2);

    % Red x marks actual ignition point used.
    plot(ax, xIgn, yIgn, 'rx', 'MarkerSize', 12, 'LineWidth', 3);
end

% Create a solid red RGB image used as the burn overlay.
% Transparency is controlled separately by the burn mask.
redOverlay = zeros(H,W,3, 'uint8');
redOverlay(:,:,1) = 255;

% Display red overlay on top of the map.
hOverlay = imshow(redOverlay, 'Parent', ax);

% Start with overlay fully transparent.
set(hOverlay, 'AlphaData', zeros(H,W));

% Loop through all burn masks and update the animation.
for i = 1:numel(maskAtTime)

    % Get burn mask for current frame.
    m = maskAtTime{i};

    % Burned pixels are shown using red overlay transparency.
    set(hOverlay, 'AlphaData', opts.alpha * double(m));

    % Update title with frame number and simulation day.
    title(ax, sprintf('Etosha Fire Spread Animation | Frame %d / %d | Day %.2f', ...
        i, numel(maskAtTime), tHours(i)/24), ...
        'FontSize', 16, 'FontWeight', 'bold');

    % Force MATLAB to display the current frame.
    drawnow;

    % If GIF saving is enabled, write this frame.
    if opts.saveGif
        write_gif_frame(figAnim, opts.gifFile, opts.gifDelayTime, i);
    end
end

end

%% ===================== HELPERS =====================

function [xPix, yPix] = latlon_to_pixel(latQ, lonQ, latGrid, lonGrid)
%LATLON_TO_PIXEL
%
% Converts latitude/longitude query points into image pixel coordinates by
% finding the nearest pixel in the latitude/longitude grids.
%
% Inputs:
%   latQ    - query latitude value(s)
%   lonQ    - query longitude value(s)
%   latGrid - latitude value at each image pixel
%   lonGrid - longitude value at each image pixel
%
% Outputs:
%   xPix    - image column index/index values
%   yPix    - image row index/index values

% Get grid dimensions.
H = size(latGrid,1);
W = size(latGrid,2);

% Allocate output arrays with the same shape as the query inputs.
xPix = zeros(size(latQ));
yPix = zeros(size(latQ));

% Flatten the latitude and longitude grids so all pixels can be searched as
% one list.
latV = latGrid(:);
lonV = lonGrid(:);

% Loop through each query point.
for k = 1:numel(latQ)

    % Compute squared distance in latitude/longitude space from the query
    % point to every pixel in the map.
    d = (latV - latQ(k)).^2 + (lonV - lonQ(k)).^2;

    % Find nearest pixel.
    [~, idx] = min(d);

    % Convert linear index to row and column.
    [r,c] = ind2sub([H,W], idx);

    % Image row becomes y coordinate.
    yPix(k) = r;

    % Image column becomes x coordinate.
    xPix(k) = c;
end

end

function d = local_meters_between(lat1, lon1, lat2, lon2)
%LOCAL_METERS_BETWEEN
%
% Computes the approximate great-circle distance between two geographic
% coordinates using the haversine formula.
%
% Inputs:
%   lat1, lon1 - first point in degrees
%   lat2, lon2 - second point in degrees
%
% Output:
%   d          - distance in meters

% Mean Earth radius in meters.
R = 6371000;

% Convert latitudes to radians.
phi1 = deg2rad(lat1);
phi2 = deg2rad(lat2);

% Compute latitude and longitude differences in radians.
dphi = deg2rad(lat2 - lat1);
dl = deg2rad(lon2 - lon1);

% Haversine intermediate value.
a = sin(dphi/2).^2 + cos(phi1).*cos(phi2).*sin(dl/2).^2;

% Convert angular distance to physical distance in meters.
d = 2 * R * atan2(sqrt(a), sqrt(1-a));

end

function Dm = cumulative_distance_budget(tHours, rateSchedule)
%CUMULATIVE_DISTANCE_BUDGET
%
% Computes cumulative spread distance at each requested time using the
% piecewise spread-rate schedule.
%
% Inputs:
%   tHours       - vector of requested times in hours
%   rateSchedule - rows of [end time in hours, speed in m/s]
%
% Output:
%   Dm           - cumulative spread distance in meters

% Allocate output vector.
Dm = zeros(size(tHours));

% Integrate the rate schedule at each requested time.
for k = 1:numel(tHours)
    Dm(k) = integrate_schedule_to_time(tHours(k), rateSchedule);
end

end

function D = integrate_schedule_to_time(t, rateSchedule)
%INTEGRATE_SCHEDULE_TO_TIME
%
% Integrates the piecewise spread-rate schedule from time 0 to time t.
%
% The spread-rate schedule uses rows of:
%   [segment end time in hours, speed in meters per second]
%
% The output is cumulative distance in meters.

% Initialize cumulative distance.
D = 0;

% Start time of the current schedule segment.
t0 = 0;

% Loop through all schedule segments.
for r = 1:size(rateSchedule,1)

    % End time of current segment in hours.
    tEnd = rateSchedule(r,1);

    % Spread speed during current segment in meters per second.
    v = rateSchedule(r,2);

    % If requested time occurs before this segment starts, stop.
    if t <= t0
        break;
    end

    % Determine how much of the current segment contributes.
    dt = min(t, tEnd) - t0;  % hours

    % Convert hours to seconds and add distance contribution.
    if dt > 0
        D = D + v * dt * 3600;  % meters
    end

    % Advance to the next segment.
    t0 = tEnd;

    % Stop after reaching the requested time.
    if t <= tEnd
        break;
    end
end

end

function T = dijkstra_travel_time(cost, x0, y0, mpp, wx, wy, anis, elev, opts)
%DIJKSTRA_TRAVEL_TIME
%
% Computes a deterministic fire spread/travel field using Dijkstra's
% shortest-path algorithm on an 8-connected image grid.
%
% Each pixel is treated as a node. Movement to neighboring pixels is weighted
% by:
%   - physical distance between pixels
%   - local moisture/dryness cost
%   - wind-direction preference
%   - optional slope/elevation effects
%
% The output T gives the minimum accumulated travel cost needed to reach
% each pixel from the ignition point.

% Get cost-field dimensions.
[H,W] = size(cost);

% Define a large value used as infinity.
INF = 1e18;

% Initialize all pixels as unreached.
T = INF * ones(H,W);

% Set ignition pixel travel cost to zero.
T(y0,x0) = 0;

% Track which pixels have been finalized by Dijkstra's algorithm.
visited = false(H,W);

% Initialize queue with ignition pixel.
Qx = x0;
Qy = y0;

% Define 8-connected neighbor offsets.
% This allows horizontal, vertical, and diagonal movement.
nbr = [-1 -1; -1 0; -1 1; 0 -1; 0 1; 1 -1; 1 0; 1 1];

% Enforce minimum anisotropy of 1.
anis = max(1.0, anis);

% Continue until all reachable queued pixels have been processed.
while ~isempty(Qx)

    % Start by assuming the first queued pixel has the minimum travel cost.
    idxMin = 1;
    tMin = T(Qy(1),Qx(1));

    % Search the queue for the pixel with the smallest travel cost.
    for i = 2:numel(Qx)
        tv = T(Qy(i),Qx(i));
        if tv < tMin
            tMin = tv;
            idxMin = i;
        end
    end

    % Remove the minimum-cost pixel from the queue.
    x = Qx(idxMin);
    y = Qy(idxMin);
    Qx(idxMin) = [];
    Qy(idxMin) = [];

    % Skip the pixel if it was already finalized earlier.
    if visited(y,x)
        continue;
    end

    % Mark this pixel as finalized.
    visited(y,x) = true;

    % Loop through all 8 neighboring pixels.
    for k = 1:8

        % Neighbor row and column.
        yy = y + nbr(k,1);
        xx = x + nbr(k,2);

        % Skip neighbors outside the image.
        if xx < 1 || xx > W || yy < 1 || yy > H
            continue;
        end

        % Skip neighbors already finalized.
        if visited(yy,xx)
            continue;
        end

        % Step direction in row/column form.
        step = nbr(k,:);

        % Convert pixel step to physical distance.
        % Diagonal steps are longer than horizontal/vertical steps.
        dist = mpp * norm(step);

        % Convert row/column step into image x/y movement direction.
        mv = [step(2), step(1)];

        % Normalize movement vector.
        mv = mv / max(norm(mv),1e-9);

        % Compute movement alignment with wind direction.
        dotw = mv(1)*wx + mv(2)*wy;

        % Reduce cost for downwind movement.
        % Movement not aligned with wind does not receive this benefit.
        dirFactor = exp(-log(anis) * max(dotw,0));

        % Combine local cost with wind-direction factor.
        wcost = cost(yy,xx) * dirFactor;

        % Add elevation/slope effect if enabled.
        if opts.useElevation

            % Elevation difference from current pixel to neighbor.
            dz = elev(yy,xx) - elev(y,x);

            % Approximate local slope over the step distance.
            slope = dz / max(dist, 1e-9);

            % Convert slope into a multiplicative cost factor.
            slopeFactor = exp(-opts.slopeWeight * slope);

            % Clamp slope factor to avoid extreme values.
            slopeFactor = min(max(slopeFactor, 0.4), 2.5);

            % Apply slope effect.
            wcost = wcost * slopeFactor;
        end

        % Candidate accumulated cost to reach the neighbor through the
        % current pixel.
        cand = T(y,x) + dist * wcost;

        % If this candidate path is better, update the neighbor.
        if cand < T(yy,xx)

            % Store improved travel cost.
            T(yy,xx) = cand;

            % Add neighbor to queue for later processing.
            Qx(end+1) = xx;
            Qy(end+1) = yy;
        end
    end
end

% Keep nonfinite values at the infinity placeholder.
T(~isfinite(T)) = INF;

end

function write_gif_frame(figHandle, gifFile, delayTime, frameIdx)
%WRITE_GIF_FRAME
%
% Captures the current animation figure frame and writes it to a GIF file.
%
% On the first frame, a new GIF is created. On later frames, the new image
% is appended to the existing GIF.
%
% Inputs:
%   figHandle - figure handle to capture
%   gifFile   - output GIF filename
%   delayTime - delay between frames in seconds
%   frameIdx  - current frame number

% If the figure handle is empty or invalid, do nothing.
if isempty(figHandle) || ~ishandle(figHandle)
    return;
end

% Force MATLAB to render the latest figure frame before capturing.
drawnow;

% Capture the current figure frame.
fr = getframe(figHandle);

% Convert captured frame to image data.
img = frame2im(fr);

% Convert RGB image to indexed image format required for GIFs.
[imind, cm] = rgb2ind(img, 256);

% If this is the first frame, create a new looping GIF.
if frameIdx == 1
    imwrite(imind, cm, gifFile, 'gif', 'Loopcount', inf, 'DelayTime', delayTime);
else

    % Otherwise, append the frame to the existing GIF.
    imwrite(imind, cm, gifFile, 'gif', 'WriteMode', 'append', 'DelayTime', delayTime);
end

end
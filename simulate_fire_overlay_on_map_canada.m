function out = simulate_fire_overlay_on_map_canada(I_map, latGrid, lonGrid, ...
    latPoly, lonPoly, ignLat, ignLon, daysTotal, opts)
%SIMULATE_FIRE_OVERLAY_ON_MAP_CANADA
%
% This function simulates wildfire spread for the Canada / US-Canada
% international collaboration wildfire scenario.
%
% The model starts from a specified ignition location, converts that
% ignition point into map pixel coordinates, and spreads the fire through a
% deterministic spatial cost field. The spread is constrained so that it
% never grows outside the extracted final fire perimeter polygon.
%
% The fire growth is scaled so that the final simulated burn mask matches
% the known perimeter at day = daysTotal.
%
% The function also produces:
%   - burn masks at each time step
%   - burned area history in acres
%   - deterministic spread-field heatmap
%   - deterministic spread-field contours
%   - burn area versus time plot
%   - fire spread animation overlay
%   - optional GIF export
%
% Outputs:
%   out.maskAtTime           - burn masks over time
%   out.tHours               - time vector [hours]
%   out.areaAcresMask        - area history from mask [acres]
%   out.targetAcres          - final target mask area [acres]
%   out.ignPixRequested      - requested ignition pixel [x y]
%   out.ignPixUsed           - actual ignition pixel used [x y]
%   out.ignLatLonRequested   - requested ignition lat/lon [lat lon]
%   out.ignLatLonUsed        - actual ignition lat/lon [lat lon]
%   out.targetMask           - rasterized final perimeter mask
%   out.T                    - travel distance field
%   out.mpp                  - meters per pixel
%   out.areaAcres            - alias of areaAcresMask

% If the caller did not provide an options structure, create an empty one.
% Default values will be assigned below.
if nargin < 9
    opts = struct();
end

% -------------------- Defaults --------------------
% These default settings define the baseline Canada-specific simulation
% behavior unless the user provides different values in opts.

% Wind direction in degrees using meteorological convention.
% This means the direction the wind is coming FROM.
if ~isfield(opts,'windDirFromDeg'),       opts.windDirFromDeg = 315; end

% Wind anisotropy controls how strongly the fire prefers to spread downwind.
% Larger values make downwind spread easier relative to other directions.
if ~isfield(opts,'anisotropy'),           opts.anisotropy = 2.8; end

% Time spacing between saved frames in the simulation and animation.
if ~isfield(opts,'frameStepHours'),       opts.frameStepHours = 6; end

% Transparency of the red burned-area overlay.
if ~isfield(opts,'alpha'),                opts.alpha = 0.35; end

% Enables the map-image-based moisture/dryness proxy.
if ~isfield(opts,'useMoisture'),          opts.useMoisture = true; end

% Enables optional elevation/slope effects.
if ~isfield(opts,'useElevation'),         opts.useElevation = false; end

% Weight applied to the image-derived wetness field.
% Higher values increase the penalty for wetter-looking regions.
if ~isfield(opts,'moistureWeight'),       opts.moistureWeight = 1.35; end

% Weight applied to slope effects if elevation is used.
if ~isfield(opts,'slopeWeight'),          opts.slopeWeight = 2.0; end

% Elevation grid. This is only used if opts.useElevation = true.
if ~isfield(opts,'elevGrid'),             opts.elevGrid = []; end

% Optional random patchiness used for visual irregularity.
% A value of zero keeps the burn mask fully deterministic.
if ~isfield(opts,'patchiness'),           opts.patchiness = 0; end

% If the requested ignition point is outside the final perimeter, this
% option moves it to the nearest pixel inside the target perimeter.
if ~isfield(opts,'snapIgnitionToTarget'), opts.snapIgnitionToTarget = true; end

% Controls whether requested and actual ignition markers appear on plots.
if ~isfield(opts,'showIgnitionMarker'),   opts.showIgnitionMarker = true; end

% Controls whether the animation should be saved as a GIF.
if ~isfield(opts,'saveGif'),              opts.saveGif = false; end

% Default output GIF filename.
if ~isfield(opts,'gifFile'),              opts.gifFile = 'canada_fire_animation.gif'; end

% Delay between GIF frames in seconds.
if ~isfield(opts,'gifDelayTime'),         opts.gifDelayTime = 0.20; end

% Optional manual override for ignition pixel location.
% If provided, this takes priority over ignLat and ignLon.
if ~isfield(opts,'ignPixOverride'),       opts.ignPixOverride = []; end

% Toggle for deterministic spread-field heatmap.
if ~isfield(opts,'makeTfieldHeatmap'),    opts.makeTfieldHeatmap = true; end

% Toggle for deterministic spread-field contour plot.
if ~isfield(opts,'makeTfieldContours'),   opts.makeTfieldContours = true; end

% Transparency for the deterministic spread-field heatmap overlay.
if ~isfield(opts,'tfieldAlpha'),          opts.tfieldAlpha = 0.45; end

% Number of contour levels used for the deterministic spread field.
if ~isfield(opts,'nContourLevels'),       opts.nContourLevels = 6; end

% If no rate schedule is provided, use a Canada-specific spread profile.
% Each row is [end time in hours, spread speed in meters per second].
if ~isfield(opts,'rateSchedule')
    % Canada-specific inferred growth profile:
    %   - very fast early expansion
    %   - remains aggressive for the first few days
    %   - slows but continues broad fill-in
    %   - low-speed fill-in by perimeter date
    opts.rateSchedule = [
         6,   4.2;
        12,   3.9;
        18,   3.5;
        24,   3.1;
        36,   2.6;
        48,   2.2;
        60,   1.9;
        72,   1.6;
        96,   1.25;
       120,   1.00;
       144,   0.78;
       168,   0.62;
       192,   0.52;
       216,   0.44;
       240,   0.38;
       24*daysTotal, 0.32
    ];
end

% Store the map image height and width.
H = size(I_map,1);
W = size(I_map,2);

% Print debug information about the ignition inputs.
% This is useful for checking whether the requested ignition point lands in
% the expected location on the map.
fprintf('\n--- DEBUG IGNITION INPUTS (CANADA) ---\n');
fprintf('Input ignLat = %.6f, ignLon = %.6f\n', ignLat, ignLon);

% Print whether a manual ignition pixel override was supplied.
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

% Convert the polygon coordinates into a binary image mask.
% Pixels inside the final perimeter are true.
targetMask = poly2mask(xPoly, yPoly, H, W);

% Stop if the perimeter did not rasterize correctly.
% An empty mask means no pixels were identified inside the polygon.
if ~any(targetMask(:))
    error('Target perimeter rasterized to an empty mask.');
end

% -------------------- Requested ignition pixel --------------------
% Determine the requested ignition pixel. A manual pixel override is used if
% supplied. Otherwise, the ignition latitude/longitude is converted to the
% nearest image pixel.
if ~isempty(opts.ignPixOverride) && numel(opts.ignPixOverride) == 2

    % Use manually supplied ignition pixel.
    xIgnReq = round(opts.ignPixOverride(1));
    yIgnReq = round(opts.ignPixOverride(2));
else

    % Convert ignition latitude/longitude to pixel coordinates.
    [xIgnReq, yIgnReq] = latlon_to_pixel(ignLat, ignLon, latGrid, lonGrid);

    % Round to integer pixel indices.
    xIgnReq = round(xIgnReq);
    yIgnReq = round(yIgnReq);
end

% Keep the requested ignition point within valid image bounds.
% The point is kept at least one pixel away from the outer border to avoid
% indexing problems when checking neighboring pixels.
xIgnReq = max(2, min(W-1, xIgnReq));
yIgnReq = max(2, min(H-1, yIgnReq));

% Store the latitude/longitude corresponding to the requested ignition
% pixel after bounds checking.
reqLat = latGrid(yIgnReq, xIgnReq);
reqLon = lonGrid(yIgnReq, xIgnReq);

% Initialize the actual ignition location as the requested ignition.
% It may be changed below if the requested point is outside the target mask.
xIgn = xIgnReq;
yIgn = yIgnReq;

% Print requested and initially used ignition pixel coordinates.
fprintf('Requested ignition pixel: (%d,%d)\n', xIgnReq, yIgnReq);
fprintf('Used ignition pixel: (%d,%d)\n', xIgn, yIgn);

% If requested ignition is outside the perimeter, snap it to the nearest
% pixel inside the target mask.
if opts.snapIgnitionToTarget && ~targetMask(yIgn, xIgn)

    % Find all pixel rows and columns inside the target perimeter.
    [yyT, xxT] = find(targetMask);

    % Compute squared pixel distance from the requested ignition location to
    % every valid target-mask pixel.
    d2 = (double(xxT) - double(xIgn)).^2 + (double(yyT) - double(yIgn)).^2;

    % Find the nearest target-mask pixel.
    [~, iMin] = min(d2);

    % Use the nearest target-mask pixel as the actual ignition location.
    xIgn = xxT(iMin);
    yIgn = yyT(iMin);

    % Print debug information describing the snap operation.
    fprintf('Requested ignition pixel (%d,%d) was outside target mask.\n', xIgnReq, yIgnReq);
    fprintf('Snapped ignition to nearest target pixel (%d,%d).\n', xIgn, yIgn);
else

    % If the requested point was already inside the target mask, keep it.
    fprintf('Ignition pixel inside target mask: (%d,%d)\n', xIgn, yIgn);
end

% Store the latitude/longitude corresponding to the actual ignition point.
useLat = latGrid(yIgn, xIgn);
useLon = lonGrid(yIgn, xIgn);

% Print the requested and actual ignition coordinates for verification.
fprintf('Requested ignition lat/lon: %.6f, %.6f\n', reqLat, reqLon);
fprintf('Actual used ignition lat/lon: %.6f, %.6f\n', useLat, useLon);

% -------------------- meters per pixel --------------------
% Estimate pixel size in meters using local latitude/longitude spacing near
% the ignition point.

% Estimate distance from the ignition pixel to the neighboring pixel in the
% x-direction.
dx_m = local_meters_between( ...
    latGrid(yIgn,xIgn), lonGrid(yIgn,xIgn), ...
    latGrid(yIgn,xIgn), lonGrid(yIgn,min(W,xIgn+1)));

% Estimate distance from the ignition pixel to the neighboring pixel in the
% y-direction.
dy_m = local_meters_between( ...
    latGrid(yIgn,xIgn), lonGrid(yIgn,xIgn), ...
    latGrid(min(H,yIgn+1),xIgn), lonGrid(min(H,yIgn+1),xIgn));

% Use the average of x and y spacing as the representative meters per pixel.
mpp = mean([dx_m, dy_m]);

% Stop if the pixel-size calculation failed.
if ~isfinite(mpp) || mpp <= 0
    error('Could not estimate meters-per-pixel from lat/lon grids.');
end

% Convert one pixel area into acres.
% mpp^2 gives square meters per pixel.
acrePerPixel = (mpp^2) * 0.000247105381;

% -------------------- Moisture/dryness proxy cost --------------------
% Initialize the spatial spread cost as neutral everywhere.
% Values greater than 1 slow spread. Values less than 1 speed spread.
moistCost = ones(H,W);

% If enabled, estimate a spatial moisture/dryness cost from the background
% map image.
if opts.useMoisture

    % Convert the map image to grayscale double precision.
    Ig = im2double(im2gray(I_map));

    % Smooth the grayscale image to capture broad brightness patterns.
    Ig_blur  = imgaussfilt(Ig, 6);

    % Treat darker smoothed regions as relatively wetter/more resistant.
    wet_dark = 1 - mat2gray(Ig_blur);

    % Compute image gradients to capture texture and local variation.
    [Gx, Gy] = imgradientxy(Ig);

    % Combine x and y gradients into a gradient magnitude.
    gradmag = hypot(Gx, Gy);

    % Smooth and normalize the gradient field to form a ruggedness proxy.
    rugged  = mat2gray(imgaussfilt(gradmag, 2));

    % Combine darkness and smoothness into a wetness proxy.
    % Darker and less rugged areas become more resistant to spread.
    wetness = 0.70*wet_dark + 0.30*(1 - rugged);

    % Clamp wetness values to the range [0, 1].
    wetness = min(max(wetness,0),1);

    % Convert wetness into a multiplicative cost field.
    moistCost = exp(opts.moistureWeight * wetness);

    % Clamp cost values to avoid unstable or unrealistic extremes.
    moistCost = min(max(moistCost, 0.6), 3.0);
end

% -------------------- Elevation (optional) --------------------
% Initialize the elevation grid as empty.
elev = [];

% If elevation effects are enabled, validate and resize the elevation grid.
if opts.useElevation

    % Pull the elevation grid from the options structure.
    elev = opts.elevGrid;

    % If no elevation grid was provided, disable elevation effects.
    if isempty(elev)
        warning('opts.useElevation=true but opts.elevGrid empty. Disabling elevation effect.');
        opts.useElevation = false;
    else

        % If elevation grid size does not match the image, resize it so that
        % each image pixel has a corresponding elevation value.
        if ~isequal(size(elev,1),H) || ~isequal(size(elev,2),W)
            elev = imresize(elev, [H W], 'bilinear');
        end
    end
end

% -------------------- Wind unit vector in image coords --------------------
% opts.windDirFromDeg is the meteorological FROM direction.
% The propagation model needs the direction the wind blows TO, so the
% direction is rotated by 180 degrees.
dirTo = mod(opts.windDirFromDeg + 180, 360);

% Convert the wind direction into image-coordinate vector components.
% +x is right/east and +y is down/south in image coordinates.
wx = sind(dirTo);
wy = -cosd(dirTo);

% Normalize the wind vector.
wn = hypot(wx, wy);
wx = wx / max(wn, 1e-12);
wy = wy / max(wn, 1e-12);

% -------------------- Travel distance field --------------------
% Compute the deterministic spread/travel field from the ignition point.
% Lower values in Tfield indicate pixels that are easier or earlier to reach.
Tfield = dijkstra_travel_time(moistCost, xIgn, yIgn, mpp, wx, wy, ...
    opts.anisotropy, elev, opts);

% -------------------- Time grid --------------------
% Convert total simulation duration from days to hours.
Tend_hours = daysTotal * 24;

% Create the simulation time vector using the requested frame spacing.
tHours = 0:opts.frameStepHours:Tend_hours;

% Ensure the final time is included exactly.
if isempty(tHours) || tHours(end) < Tend_hours
    tHours(end+1) = Tend_hours;
end

% Ensure the spread-rate schedule extends to the final simulation time.
% If not, append a final schedule row using the last available speed.
if opts.rateSchedule(end,1) < Tend_hours
    opts.rateSchedule(end+1,:) = [Tend_hours, opts.rateSchedule(end,2)];
end

% -------------------- Scale distance budget to fill perimeter at end --------------------
% Extract deterministic travel-field values inside the final perimeter.
Tin = Tfield(targetMask);

% Keep only finite values.
Tin = Tin(isfinite(Tin));

% Stop if no valid travel values were found inside the target mask.
if isempty(Tin)
    error('No finite travel-time values inside target mask.');
end

% The largest travel-field value inside the perimeter is the amount needed
% to fill the final target mask.
tauEndNeeded = max(Tin);

% Compute cumulative distance allowed by the rate schedule at each time.
DmBase = cumulative_distance_budget(tHours, opts.rateSchedule);

% Scale the cumulative distance curve so that it reaches the full perimeter
% at the final simulation time.
scale = tauEndNeeded / max(DmBase(end), 1e-9);
DmBase = DmBase * scale;

% -------------------- Allocate outputs --------------------
% Allocate a cell array to store burn masks over time.
maskAtTime    = cell(numel(tHours),1);

% Allocate the burn-area history vector.
areaAcresMask = zeros(numel(tHours),1);

% -------------------- Simulate constrained growth --------------------
% Loop through each time step and determine which pixels have burned.
for i = 1:numel(tHours)

    % Core deterministic burn mask.
    % Pixels burn if their deterministic travel-field value is less than or
    % equal to the scaled distance budget at the current time.
    maskCore = (Tfield <= DmBase(i)) & targetMask;

    % Start with the deterministic core mask.
    mask = maskCore;

    % Optional patchiness can be used to visually break up the fire mask.
    % This adds random visual variation but is not part of the core
    % deterministic spread calculation.
    if opts.patchiness > 0

        % Convert moisture cost into probability of showing a burned pixel.
        pBurn = exp(-opts.patchiness * (moistCost - 1));

        % Clamp probability to avoid completely removing or filling regions.
        pBurn = min(max(pBurn, 0.05), 1.0);

        % Randomly thin the mask according to the burn probability.
        mask = mask & (rand(size(mask)) < pBurn);

        % Remove small isolated pixels.
        mask = imopen(mask, strel('disk', 1));

        % Fill small gaps in the burn mask.
        mask = imclose(mask, strel('disk', 2));
    end

    % Store the burn mask for this time step.
    maskAtTime{i} = mask;

    % Compute burned area in acres from the number of burned pixels.
    areaAcresMask(i) = nnz(mask) * acrePerPixel;
end

% Compute the final target area from the perimeter mask.
targetAcres = nnz(targetMask) * acrePerPixel;

% -------------------- Outputs --------------------
% Store burn masks over time.
out.maskAtTime          = maskAtTime;

% Store time vector in hours.
out.tHours              = tHours;

% Store burn area history in acres.
out.areaAcresMask       = areaAcresMask;

% Store final target area in acres.
out.targetAcres         = targetAcres;

% Store requested ignition pixel.
out.ignPixRequested     = [xIgnReq yIgnReq];

% Store actual ignition pixel used.
out.ignPixUsed          = [xIgn yIgn];

% Store requested ignition latitude/longitude.
out.ignLatLonRequested  = [reqLat reqLon];

% Store actual ignition latitude/longitude used.
out.ignLatLonUsed       = [useLat useLon];

% Store rasterized final perimeter.
out.targetMask          = targetMask;

% Store deterministic travel/spread field.
out.T                   = Tfield;

% Store meters-per-pixel estimate.
out.mpp                 = mpp;

% Store alias for burn area history.
out.areaAcres           = areaAcresMask;

% -------------------- Intermediate deterministic spread-field visualizations --------------------
% Create a copy of the travel field for visualization.
Tvis = Tfield;

% Hide values outside the final perimeter.
Tvis(~targetMask) = NaN;

% Extract finite values inside the target perimeter.
finiteT = Tvis(isfinite(Tvis));

% Only create deterministic spread-field visualizations if valid values
% exist inside the final perimeter.
if ~isempty(finiteT)

    % Normalize the spread field between 0 and 1 for plotting.
    Tnorm = (Tvis - min(finiteT)) ./ max(max(finiteT) - min(finiteT), eps);

    % =========================
    % Figure 1: semi-transparent Tfield heatmap
    % =========================
    if opts.makeTfieldHeatmap

        % Create figure for deterministic spread-field heatmap.
        figT = figure('Name','Deterministic Spread Field Heatmap','Color','w');

        % Create axes inside the figure.
        axT = axes(figT); %#ok<LAXES>

        % Display the original map image.
        imshow(I_map, 'Parent', axT);
        hold(axT,'on');

        % Overlay normalized deterministic spread field.
        hT = imagesc(axT, Tnorm);

        % Apply transparency so the map remains visible underneath.
        % The heatmap appears only inside the target perimeter.
        set(hT, 'AlphaData', opts.tfieldAlpha * double(targetMask & isfinite(Tnorm)));

        % Use turbo colormap for high-contrast spread-field visualization.
        colormap(axT, turbo);

        % Add colorbar showing normalized deterministic arrival metric.
        cb = colorbar(axT);
        cb.Label.String = 'Normalized Deterministic Arrival Metric';
        cb.Label.Interpreter = 'latex';
        cb.TickLabelInterpreter = 'latex';

        % Plot final perimeter outline.
        plot(axT, xPoly, yPoly, '-', 'Color', [1 0.9 0], 'LineWidth', 2.0);

        % Optionally plot requested and actual ignition markers.
        if opts.showIgnitionMarker

            % Cyan circle marks the requested ignition point.
            plot(axT, xIgnReq, yIgnReq, 'co', 'MarkerSize', 10, 'LineWidth', 2);

            % Red-filled marker marks the actual ignition point used.
            plot(axT, xIgn, yIgn, 'wo', ...
                'MarkerFaceColor', [0.85 0.1 0.1], ...
                'MarkerEdgeColor', 'k', ...
                'MarkerSize', 8);
        end

        % Add title using LaTeX formatting.
        title(axT, 'Deterministic Spread Field $T(\mathbf{x})$', ...
            'Interpreter','latex', 'FontSize', 16);

        % Apply consistent axis formatting.
        set(axT, 'FontName', 'Times', 'FontSize', 12, ...
            'TickLabelInterpreter','latex', 'LineWidth', 1.0);
    end

    % =========================
    % Figure 2: contour lines of Tfield
    % =========================
    if opts.makeTfieldContours

        % Create figure for deterministic spread-field contours.
        figC = figure('Name','Deterministic Spread Field Contours','Color','w');

        % Create axes inside the figure.
        axC = axes(figC); %#ok<LAXES>

        % Display the original map image.
        imshow(I_map, 'Parent', axC);
        hold(axC,'on');

        % Add faint normalized spread-field background.
        hBase = imagesc(axC, Tnorm);

        % Make the background semi-transparent and limited to the perimeter.
        set(hBase, 'AlphaData', 0.18 * double(targetMask & isfinite(Tnorm)));

        % Use parula colormap for the faint background.
        colormap(axC, parula);

        % Copy the full travel field for contour plotting.
        Tcont = Tfield;

        % Hide travel-field values outside the final perimeter.
        Tcont(~targetMask) = NaN;

        % Define contour levels between the min and max travel-field values.
        tLevels = linspace(min(finiteT), max(finiteT), opts.nContourLevels + 2);

        % Remove the extreme levels so labels/contours are easier to read.
        tLevels = tLevels(2:end-1);

        % Draw contour lines of the deterministic spread field.
        [C,hContour] = contour(axC, Tcont, tLevels, ...
            'LineColor', 'w', 'LineWidth', 1.4);

        % Label contour lines.
        clabel(C, hContour, 'Color', 'w', 'FontSize', 9, ...
            'Interpreter', 'latex', 'LabelSpacing', 350);

        % Plot final perimeter outline.
        plot(axC, xPoly, yPoly, '-', 'Color', [1 0.9 0], 'LineWidth', 2.0);

        % Optionally plot requested and actual ignition markers.
        if opts.showIgnitionMarker

            % Cyan circle marks the requested ignition point.
            plot(axC, xIgnReq, yIgnReq, 'co', 'MarkerSize', 10, 'LineWidth', 2);

            % Red-filled marker marks the actual ignition point used.
            plot(axC, xIgn, yIgn, 'wo', ...
                'MarkerFaceColor', [0.85 0.1 0.1], ...
                'MarkerEdgeColor', 'k', ...
                'MarkerSize', 8);
        end

        % Add title.
        title(axC, 'Contours of Deterministic Spread Field', ...
            'Interpreter','latex', 'FontSize', 16);

        % Apply consistent axis formatting.
        set(axC, 'FontName', 'Times', 'FontSize', 12, ...
            'TickLabelInterpreter','latex', 'LineWidth', 1.0);
    end
end

% -------------------- Burn area plot --------------------
% Create figure showing burn area growth over time.
figure('Name','Canada Burn Area vs. Time','Color','w');

% Plot burn area versus time in days.
plot(tHours/24, areaAcresMask, 'LineWidth', 2.5);

% Turn on grid and box for readability.
grid on;
box on;

% Label x-axis.
xlabel('Time [Days]','FontSize',12);

% Label y-axis.
ylabel('Burn Area [Acres]','FontSize',12);

% Add plot title.
title('Canada Burn Area vs. Time', 'FontSize', 13);

% Add vertical line at the final perimeter-matching day.
xline(daysTotal, '--k', sprintf('Day %.1f (perimeter match)', daysTotal), ...
    'LabelVerticalAlignment','bottom', ...
    'LabelHorizontalAlignment','left');

% Add horizontal line at the target final burned area.
yline(targetAcres, '--', 'Target final acres', ...
    'LabelHorizontalAlignment','left');

% Set x-axis limits from day 0 to final simulation day.
xlim([0 max(tHours)/24]);

% Set y-axis limit slightly above maximum burned area.
ylim([0 1.05*max(areaAcresMask)]);

% Set axis font size.
set(gca,'FontSize',11);

% -------------------- Animation overlay --------------------
% Create figure for the fire spread animation.
figAnim = figure('Name','Canada Fire Spread (Animation - maskAtTime)','Color','w');

% Create axes for the animation.
ax = axes(figAnim); %#ok<LAXES>

% Show the original map image as the background.
imshow(I_map, 'Parent', ax);
hold(ax, 'on');

% Plot final perimeter outline.
plot(ax, xPoly, yPoly, 'y-', 'LineWidth', 2);

% Optionally show ignition markers in the animation.
if opts.showIgnitionMarker

    % Cyan circle marks the requested ignition point.
    plot(ax, xIgnReq, yIgnReq, 'co', 'MarkerSize', 10, 'LineWidth', 2);

    % Red x marks the actual ignition point used.
    plot(ax, xIgn, yIgn, 'rx', 'MarkerSize', 12, 'LineWidth', 3);
end

% Create a red RGB image to use as the burn overlay.
% The image itself is solid red, but its transparency will be changed based
% on the burn mask at each time step.
redOverlay = zeros(H,W,3, 'uint8');
redOverlay(:,:,1) = 255;

% Display the red overlay on top of the map.
hOverlay = imshow(redOverlay, 'Parent', ax);

% Start with the overlay fully transparent.
set(hOverlay, 'AlphaData', zeros(H,W));

% Loop through each saved burn mask and update the overlay.
for i = 1:numel(maskAtTime)

    % Retrieve burn mask for the current time.
    m = maskAtTime{i};

    % Make burned pixels visible and unburned pixels transparent.
    set(hOverlay, 'AlphaData', opts.alpha * double(m));

    % Update animation title with frame number and simulation day.
    title(ax, sprintf('Canada Fire Spread Animation (%d/%d) | Day %.2f', ...
        i, numel(maskAtTime), tHours(i)/24), ...
        'FontSize', 16, 'FontWeight', 'bold');

    % Force MATLAB to update the displayed frame.
    drawnow;

    % If enabled, write the current frame to the GIF file.
    if opts.saveGif
        write_gif_frame(figAnim, opts.gifFile, opts.gifDelayTime, i);
    end
end

end

%% ===================== HELPERS =====================

function [xPix, yPix] = latlon_to_pixel(latQ, lonQ, latGrid, lonGrid)
%LATLON_TO_PIXEL
%
% Converts latitude/longitude query points into pixel coordinates by finding
% the nearest pixel in the provided latitude and longitude grids.
%
% Inputs:
%   latQ    - query latitude value(s)
%   lonQ    - query longitude value(s)
%   latGrid - latitude value at each map pixel
%   lonGrid - longitude value at each map pixel
%
% Outputs:
%   xPix    - image column index/index values
%   yPix    - image row index/index values

% Get grid dimensions.
H = size(latGrid,1);
W = size(latGrid,2);

% Allocate output arrays with the same shape as the query input.
xPix = zeros(size(latQ));
yPix = zeros(size(latQ));

% Flatten latitude and longitude grids into column vectors.
% This makes it easy to search all pixels as one list.
latV = latGrid(:);
lonV = lonGrid(:);

% Loop through each query coordinate.
for k = 1:numel(latQ)

    % Compute squared distance in latitude/longitude space from the query
    % point to every pixel in the grid.
    d = (latV - latQ(k)).^2 + (lonV - lonQ(k)).^2;

    % Find the closest pixel.
    [~, idx] = min(d);

    % Convert the linear index back to row and column.
    [r,c] = ind2sub([H,W], idx);

    % y corresponds to image row.
    yPix(k) = r;

    % x corresponds to image column.
    xPix(k) = c;
end

end

function d = local_meters_between(lat1, lon1, lat2, lon2)
%LOCAL_METERS_BETWEEN
%
% Computes the approximate great-circle distance between two geographic
% points using the haversine formula.
%
% Inputs:
%   lat1, lon1 - first point in degrees
%   lat2, lon2 - second point in degrees
%
% Output:
%   d          - distance between the points in meters

% Mean Earth radius in meters.
R = 6371000;

% Convert latitudes to radians.
phi1 = deg2rad(lat1);
phi2 = deg2rad(lat2);

% Compute differences in latitude and longitude in radians.
dphi = deg2rad(lat2 - lat1);
dl = deg2rad(lon2 - lon1);

% Haversine formula intermediate term.
a = sin(dphi/2).^2 + cos(phi1).*cos(phi2).*sin(dl/2).^2;

% Convert angular separation into meters.
d = 2 * R * atan2(sqrt(a), sqrt(1-a));

end

function Dm = cumulative_distance_budget(tHours, rateSchedule)
%CUMULATIVE_DISTANCE_BUDGET
%
% Computes cumulative spread distance at each requested time using the
% piecewise rate schedule.
%
% Inputs:
%   tHours       - vector of requested times in hours
%   rateSchedule - rows of [end time in hours, speed in m/s]
%
% Output:
%   Dm           - cumulative distance budget in meters

% Allocate output vector.
Dm = zeros(size(tHours));

% Integrate the spread-rate schedule at each requested time.
for k = 1:numel(tHours)
    Dm(k) = integrate_schedule_to_time(tHours(k), rateSchedule);
end

end

function D = integrate_schedule_to_time(t, rateSchedule)
%INTEGRATE_SCHEDULE_TO_TIME
%
% Integrates the piecewise fire spread-rate schedule from time 0 to time t.
%
% The rate schedule is expressed as:
%   [segment end time in hours, speed in meters per second]
%
% The result is a cumulative distance in meters.

% Initialize cumulative distance.
D = 0;

% Start time of the current schedule segment.
t0 = 0;

% Loop through each spread-rate segment.
for r = 1:size(rateSchedule,1)

    % End time of the current segment in hours.
    tEnd = rateSchedule(r,1);

    % Spread speed during this segment in meters per second.
    v = rateSchedule(r,2);

    % If the requested time occurs before this segment begins, stop.
    if t <= t0
        break;
    end

    % Determine how much of this segment is included.
    dt = min(t, tEnd) - t0;

    % Convert hours to seconds and accumulate distance.
    if dt > 0
        D = D + v * dt * 3600;
    end

    % Advance the segment start time.
    t0 = tEnd;

    % Stop once the requested time has been reached.
    if t <= tEnd
        break;
    end
end

end

function T = dijkstra_travel_time(cost, x0, y0, mpp, wx, wy, anis, elev, opts)
%DIJKSTRA_TRAVEL_TIME
%
% Computes a deterministic fire spread/travel field using Dijkstra's
% shortest-path algorithm on an 8-connected pixel grid.
%
% Each pixel is treated as a node. Moving from one pixel to a neighboring
% pixel has a cost based on:
%   - physical pixel distance
%   - local moisture/dryness cost
%   - wind direction and anisotropy
%   - optional elevation/slope effects
%
% The output T stores the minimum accumulated travel cost needed to reach
% every pixel from the ignition point.

% Get size of the cost field.
[H,W] = size(cost);

% Define a large number used as infinity.
INF = 1e18;

% Initialize all pixels as unreached.
T = INF * ones(H,W);

% The ignition pixel has zero travel cost.
T(y0,x0) = 0;

% Track which pixels have already been finalized.
visited = false(H,W);

% Initialize queue with ignition pixel.
Qx = x0;
Qy = y0;

% Define 8-connected neighbors:
% up-left, up, up-right, left, right, down-left, down, down-right.
nbr = [-1 -1; -1 0; -1 1; 0 -1; 0 1; 1 -1; 1 0; 1 1];

% Force anisotropy to be at least 1.
anis = max(1.0, anis);

% Continue until no queued pixels remain.
while ~isempty(Qx)

    % Find the queued pixel with the lowest current travel cost.
    idxMin = 1;
    tMin = T(Qy(1),Qx(1));

    % Manual minimum search over the queue.
    for i = 2:numel(Qx)
        tv = T(Qy(i),Qx(i));
        if tv < tMin
            tMin = tv;
            idxMin = i;
        end
    end

    % Remove the selected pixel from the queue.
    x = Qx(idxMin);
    y = Qy(idxMin);
    Qx(idxMin) = [];
    Qy(idxMin) = [];

    % Skip if this pixel has already been finalized.
    if visited(y,x)
        continue;
    end

    % Mark this pixel as finalized.
    visited(y,x) = true;

    % Check each neighboring pixel.
    for k = 1:8

        % Candidate neighbor row and column.
        yy = y + nbr(k,1);
        xx = x + nbr(k,2);

        % Skip neighbors outside image boundaries.
        if xx < 1 || xx > W || yy < 1 || yy > H
            continue;
        end

        % Skip neighbors already finalized.
        if visited(yy,xx)
            continue;
        end

        % Current neighbor step direction.
        step = nbr(k,:);

        % Convert pixel step into physical distance.
        % Diagonal movement has larger distance than horizontal/vertical.
        dist = mpp * norm(step);

        % Convert row/column movement into image x/y vector.
        mv = [step(2), step(1)];

        % Normalize movement vector.
        mv = mv / max(norm(mv), 1e-9);

        % Compute alignment between movement direction and wind direction.
        dotw = mv(1)*wx + mv(2)*wy;

        % Reduce movement cost when moving downwind.
        % max(dotw,0) means only downwind alignment receives a benefit.
        dirFactor = exp(-log(anis) * max(dotw,0));

        % Combine local cost with wind effect.
        wcost = cost(yy,xx) * dirFactor;

        % Add optional elevation effect.
        if opts.useElevation

            % Elevation difference between neighbor and current pixel.
            dz = elev(yy,xx) - elev(y,x);

            % Approximate slope along this movement step.
            slope = dz / max(dist, 1e-9);

            % Convert slope into multiplicative cost factor.
            slopeFactor = exp(-opts.slopeWeight * slope);

            % Clamp slope factor to avoid extreme values.
            slopeFactor = min(max(slopeFactor, 0.4), 2.5);

            % Apply slope effect.
            wcost = wcost * slopeFactor;
        end

        % Candidate accumulated travel cost through current pixel.
        cand = T(y,x) + dist * wcost;

        % If this path improves the neighbor's best known cost, update it.
        if cand < T(yy,xx)

            % Store improved travel cost.
            T(yy,xx) = cand;

            % Add neighbor to queue for future processing.
            Qx(end+1) = xx; 
            Qy(end+1) = yy; 
        end
    end
end

% Preserve unreached or nonfinite values as the large INF value.
T(~isfinite(T)) = INF;

end

function write_gif_frame(figHandle, gifFile, delayTime, frameIdx)
%WRITE_GIF_FRAME
%
% Captures the current figure frame and writes it to a GIF file.
%
% On the first frame, the GIF file is created. On later frames, the image is
% appended to the existing GIF.
%
% Inputs:
%   figHandle - figure handle to capture
%   gifFile   - output GIF filename
%   delayTime - frame delay time in seconds
%   frameIdx  - current frame index

% If the figure handle is invalid, do nothing.
if isempty(figHandle) || ~ishandle(figHandle)
    return;
end

% Make sure the figure is fully rendered before capturing.
drawnow;

% Capture the current figure frame.
fr = getframe(figHandle);

% Convert the captured frame to an image.
img = frame2im(fr);

% Convert RGB image to indexed image format required for GIF writing.
[imind, cm] = rgb2ind(img, 256);

% First frame creates a new looping GIF.
if frameIdx == 1
    imwrite(imind, cm, gifFile, 'gif', 'Loopcount', inf, 'DelayTime', delayTime);
else

    % Later frames are appended to the existing GIF.
    imwrite(imind, cm, gifFile, 'gif', 'WriteMode', 'append', 'DelayTime', delayTime);
end

end
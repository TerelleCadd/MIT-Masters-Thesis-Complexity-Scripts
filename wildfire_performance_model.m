function perf = wildfire_performance_model(cfg, resources)
% WILDFIRE_PERFORMANCE_MODEL
%
% This function runs the wildfire performance model used in the thesis.
% It supports multiple wildfire scenarios, including Butte County, Etosha
% National Park, and US/Canadian wildfire cases. The function can operate
% in either full mode or fast mode.
%
% In full mode, the script:
%   1. Loads a wildfire perimeter or burn-scar screenshot.
%   2. Extracts the fire boundary from the image.
%   3. Downloads matching Google Static Maps imagery.
%   4. Aligns the screenshot to the map using feature matching.
%   5. Converts the fire boundary from image pixels to latitude/longitude.
%   6. Estimates the burned area.
%   7. Saves output files such as masks, overlays, CSV coordinates, and KML.
%
% In fast mode, the script skips the image-processing and map-alignment
% workflow. Instead, it uses a supplied burned-area value or a previously
% computed nominal growth curve. This is useful for large architecture
% sweeps where repeating the full image-processing workflow would be slow.
%
% Inputs:
%   cfg       - Structure containing scenario settings, map settings,
%               delay settings, plotting flags, and file paths.
%   resources - Structure containing resource/asset information used later
%               for suppression modeling.
%
% Output:
%   perf      - Structure containing performance outputs such as estimated
%               area, delay cases, suppression results, CO2 estimates, and
%               file paths for generated outputs.

    arguments
        cfg struct
        resources struct
    end

    % Initialize the output structure. Additional fields are added as the
    % model computes fire growth, area, delay, suppression, and output files.
    perf = struct();

    % -------------------- MODE FLAGS --------------------
    % These fields control whether the model runs in fast mode or full mode.
    % If a field is missing from cfg, a default value is assigned here so the
    % rest of the script can safely assume the field exists.
    if ~isfield(cfg,'fastMode'), cfg.fastMode = false; end
    if ~isfield(cfg,'A0_override_acres'), cfg.A0_override_acres = NaN; end
    if ~isfield(cfg,'selectedScenario'), cfg.selectedScenario = "Butte County"; end

    % Convert the selected scenario to a MATLAB string for easier comparison
    % throughout the script.
    scenario = string(cfg.selectedScenario);

    % -------------------- DEFAULTS --------------------
    % These are general model defaults. They define the perimeter day,
    % suppression time step, maximum suppression simulation length, natural
    % decay behavior, plotting behavior, and screenshot input behavior.
    if ~isfield(cfg,'dayPerimeter'),           cfg.dayPerimeter = 17; end
    if ~isfield(cfg,'plotSuppression'),        cfg.plotSuppression = true; end
    if ~isfield(cfg,'supp_dtHours'),           cfg.supp_dtHours = 0.25; end
    if ~isfield(cfg,'supp_tMaxDays'),          cfg.supp_tMaxDays = 40; end
    if ~isfield(cfg,'naturalHalfLifeDays'),    cfg.naturalHalfLifeDays = 2.5; end
    if ~isfield(cfg,'useEarlyNaturalDecay'),   cfg.useEarlyNaturalDecay = true; end
    if ~isfield(cfg,'naturalDecayStartDays'),  cfg.naturalDecayStartDays = 2.5; end
    if ~isfield(cfg,'doFigures'),              cfg.doFigures = true; end
    if ~isfield(cfg,'useGUIForScreenshot'),    cfg.useGUIForScreenshot = true; end

    % Detection delay defaults. These fields allow the model to test one
    % delay case or multiple delay cases in a sweep.
    if ~isfield(cfg,'detectionDelayDays'),     cfg.detectionDelayDays = 0; end
    if ~isfield(cfg,'detectionDelayDaysList'), cfg.detectionDelayDaysList = []; end
    if ~isfield(cfg,'detectionDelayLabels'),   cfg.detectionDelayLabels = strings(0,1); end
    if ~isfield(cfg,'delaySlopeAcresPerDay'),  cfg.delaySlopeAcresPerDay = NaN; end

    % Optional nominal growth history from a previous full run. This allows
    % fast mode to reuse an already-computed fire growth curve instead of
    % regenerating one from image processing.
    if ~isfield(cfg,'nominalGrowth_tDays'),        cfg.nominalGrowth_tDays = []; end
    if ~isfield(cfg,'nominalGrowth_areaAcres'),    cfg.nominalGrowth_areaAcres = []; end
    if ~isfield(cfg,'A0_nominal_override_acres'),  cfg.A0_nominal_override_acres = NaN; end

    % Fast-mode synthetic growth fallback. If no stored growth curve is
    % available, the script can create a smooth synthetic growth curve that
    % reaches the target burned area at the perimeter day.
    if ~isfield(cfg,'synthesizeNominalGrowth'),    cfg.synthesizeNominalGrowth = true; end
    if ~isfield(cfg,'syntheticGrowthShape'),       cfg.syntheticGrowthShape = 5.0; end

    % GIF settings used by the fire-spread visualization routines.
    if ~isfield(cfg,'saveGif'),                cfg.saveGif = false; end
    if ~isfield(cfg,'gifFile'),                cfg.gifFile = "wildfire_animation.gif"; end
    if ~isfield(cfg,'gifDelayTime'),           cfg.gifDelayTime = 0.20; end

    % Initialize variables that are filled in differently depending on
    % whether the model runs in fast mode or full mode.
    outFire = [];
    area_acres = NaN;
    ignLat = NaN; 
    ignLon = NaN; 
    zoom = NaN;

    % =========================================================
    % FAST MODE
    % =========================================================
    % Fast mode skips the screenshot extraction, Google map alignment, and
    % pixel-to-geographic conversion steps. This is mainly used for large
    % architecture sweeps where repeatedly running the full image workflow
    % would be too slow.
    if cfg.fastMode

        % Fast mode requires a valid final burned-area value. This acts as
        % the nominal area at the perimeter day.
        if isnan(cfg.A0_override_acres) || cfg.A0_override_acres <= 0
            error("wildfire_performance_model: fastMode requires cfg.A0_override_acres > 0.");
        end

        % Pull optional ignition/map values from cfg if they exist. These are
        % mainly stored for output consistency and plotting metadata.
        ignLat = getFieldAny(cfg, {'ignLat'}, NaN);
        ignLon = getFieldAny(cfg, {'ignLon'}, NaN);
        zoom   = getFieldAny(cfg, {'zoom0','zoom'}, NaN);

        % In fast mode, the fire area is directly supplied rather than
        % estimated from an aligned perimeter mask.
        area_acres = cfg.A0_override_acres;

        % If a nominal growth curve was already computed, reuse it. The rest
        % of the model expects time in hours, so the stored time in days is
        % converted back to hours.
        if ~isempty(cfg.nominalGrowth_tDays) && ~isempty(cfg.nominalGrowth_areaAcres)
            outFire = struct();
            outFire.tHours    = 24 * cfg.nominalGrowth_tDays(:);
            outFire.areaAcres = cfg.nominalGrowth_areaAcres(:);

        % If no previous growth curve exists, synthesize a smooth growth
        % curve from ignition to the perimeter day.
        elseif cfg.synthesizeNominalGrowth

            % Convert the suppression time step from hours to days. If the
            % value is invalid, use a safe fallback of 0.25 hours.
            dtDays = cfg.supp_dtHours / 24;
            if ~isfinite(dtDays) || dtDays <= 0
                dtDays = 0.25 / 24;
            end

            % Use a scenario-specific growth shape. Smaller shape values
            % create a different curvature in the synthetic growth profile.
            shapeK = cfg.syntheticGrowthShape;
            if strcmpi(scenario, "Etosha National Park")
                shapeK = 3.5;
            elseif strcmpi(scenario, "US/Canadian Wildfires")
                shapeK = 4.5;
            end

            % Generate the synthetic nominal fire growth curve.
            [tSynthDays, aSynth] = synthesize_nominal_growth_curve( ...
                area_acres, cfg.dayPerimeter, dtDays, shapeK);

            % Store the synthetic curve using the same format as the full
            % fire-spread model output.
            outFire = struct();
            outFire.tHours    = 24 * tSynthDays(:);
            outFire.areaAcres = aSynth(:);

        % If no stored curve is available and synthetic growth is disabled,
        % leave the fire growth output empty.
        else
            outFire = [];
        end

    else
        % =========================================================
        % FULL MODE
        % =========================================================
        % Full mode performs the image-processing and map-registration
        % workflow. It starts with a screenshot, extracts the fire perimeter
        % or burn scar, aligns that screenshot to Google Maps imagery, and
        % converts the extracted boundary to geographic coordinates.

        % A Google Static Maps API key is required because the script
        % downloads map images for the selected fire area.
        if ~isfield(cfg,'apiKey') || strlength(string(cfg.apiKey)) == 0
            error('wildfire_performance_model:MissingAPIKey', ...
                  'cfg.apiKey is required (Google Static Maps API key).');
        end

        % Pull core scenario location settings from the configuration.
        ignLat = cfg.ignLat;
        ignLon = cfg.ignLon;
        zoom0  = cfg.zoom0;

        % By default, the Google map is centered on the ignition point.
        centerLat = ignLat;
        centerLon = ignLon;

        % Some screenshots may not be centered exactly on the ignition
        % point. These optional fields allow a different map center to be
        % used during image registration.
        if isfield(cfg,'centerLat') && isfinite(cfg.centerLat)
            centerLat = cfg.centerLat;
        end
        if isfield(cfg,'centerLon') && isfinite(cfg.centerLon)
            centerLon = cfg.centerLon;
        end

        % Map image dimensions and Google Static Maps scale factor.
        mapW  = cfg.mapW;
        mapH  = cfg.mapH;
        scale = cfg.scale;

        % Output file paths for the aligned overlay, mask, coordinate table,
        % and KML perimeter file.
        outOverlay = cfg.outOverlay;
        outMask    = cfg.outMask;
        outCSV     = cfg.outCSV;
        outKML     = cfg.outKML;

        % Minimum acceptable number of feature-matching inliers. Larger
        % values require stronger agreement between the screenshot and map.
        minInliersAccept = cfg.minInliersAccept;

        fprintf("Current folder: %s\n", pwd);
        fprintf("Scenario: %s\n", scenario);

%% ---------------- 1) PICK + LOAD SCREENSHOT ----------------
        % The screenshot is the user-provided fire image. It may show a
        % historical fire perimeter, a burn scar, or another fire boundary
        % reference depending on the selected scenario.
        if cfg.useGUIForScreenshot

            % Customize the file-selection prompt so it matches the scenario.
            switch scenario
                case "Butte County"
                    promptStr = 'Select the Butte perimeter screenshot';
                case "Etosha National Park"
                    promptStr = 'Select the Etosha burn-scar screenshot';
                case "US/Canadian Wildfires"
                    promptStr = 'Select the US/Canada wildfire screenshot';
                otherwise
                    promptStr = 'Select wildfire screenshot';
            end

            % Let the user select the screenshot interactively.
            [f,p] = uigetfile({'*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.bmp', ...
                               'Images (*.png,*.jpg,*.tif,*.bmp)'}, ...
                               promptStr);
            if isequal(f,0), error('No file selected.'); end
            snapFile = fullfile(p,f);

        else
            % If GUI selection is disabled, the screenshot path must already
            % be provided in cfg.snapFile.
            if ~isfield(cfg,'snapFile') || strlength(string(cfg.snapFile)) == 0
                error('cfg.snapFile must be provided when useGUIForScreenshot=false');
            end
            snapFile = char(cfg.snapFile);

            % Stop early if the provided screenshot path is invalid.
            if ~isfile(snapFile)
                error('Snapshot file not found: %s', snapFile);
            end
        end

        % Read the selected screenshot into MATLAB.
        fprintf("Reading screenshot: %s\n", snapFile);
        I_snap = imread(snapFile);
        
        % The Etosha screenshot includes visual content that is not part of
        % the actual burn scar, such as banners, map borders, or logos. This
        % crop removes those regions before thresholding the image.
        if strcmpi(scenario, "Etosha National Park")
            H0 = size(I_snap,1);
            W0 = size(I_snap,2);
        
            % Crop out banners, logos, and borders.
            cropRect = [40, 70, W0-120, H0-150];
            I_snap = imcrop(I_snap, cropRect);
        
            % Show the cropped image for debugging so the user can verify
            % that the retained image region contains the relevant burn scar.
            figure; imshow(I_snap); title('Etosha Cropped Image');
        end
        
        % Convert grayscale images to three-channel RGB. Later image
        % processing functions expect RGB images.
        if size(I_snap,3)==1
            I_snap = repmat(I_snap,[1 1 3]);
        end

%% ---------------- 2) EXTRACT MASK IN SCREENSHOT SPACE ----------------
        % Create a binary mask from the screenshot. The mask marks the pixels
        % that are believed to represent the fire perimeter or burn scar.
        switch scenario
            case "Butte County"
                % Butte County uses a red perimeter trace, so a red-color
                % threshold is used.
                [mask_snap, maskModeUsed] = extract_butte_red_mask(I_snap);

            case "Etosha National Park"
                % Etosha uses a darker burn-scar feature, so the script uses
                % a darkness/burn-scar threshold.
                [mask_snap, maskModeUsed] = extract_darkscar_mask(I_snap);

            case "US/Canadian Wildfires"
                % The Canada case currently uses the same dark-scar style
                % extraction as Etosha. Thresholds can be refined later for a
                % specific selected image.
                [mask_snap, maskModeUsed] = extract_darkscar_mask(I_snap);

            otherwise
                % Default to the Butte red-perimeter extraction method if an
                % unknown scenario name is supplied.
                [mask_snap, maskModeUsed] = extract_butte_red_mask(I_snap);
        end

        fprintf("Mask extraction mode: %s\n", maskModeUsed);

        % Stop if no fire pixels were detected. An empty mask means there is
        % no perimeter or burn scar to align with the map.
        if ~any(mask_snap(:))
            error("Mask extraction returned empty result.");
        end

%% ---------------- 3) TRY MULTIPLE MAP CONFIGS + PICK BEST ----------------
        % The screenshot and Google map must be aligned. The script tests
        % different Google map types, zoom levels, and geometric transform
        % models. It keeps the alignment with the most inlier feature matches.
        if scenario == "Butte County"
            % Butte uses a wider set of zoom candidates because the screenshot
            % alignment can be more sensitive to map scale.
            mapTypes = ["roadmap","satellite","terrain","hybrid"];
            zooms    = [zoom0-1, zoom0, zoom0+1];
            tforms   = ["similarity","affine"];
        else
            % Other scenarios currently use the configured zoom only.
            mapTypes = ["roadmap","satellite","terrain","hybrid"];
            zooms    = zoom0;
            tforms   = ["similarity","affine"];
        end

        % Store the best alignment result found across all attempted map
        % configurations.
        best = struct('nInliers',0,'tform',[],'I_map',[],'zoom',[],'mapType',"", ...
                      'mask_rs',[],'Rfixed',[],'I_snap_rs',[]);

        % Loop through all candidate map types, zooms, and transformation
        % models until an acceptable registration is found.
        for mt = 1:numel(mapTypes)
            for zz = 1:numel(zooms)
                for tf = 1:numel(tforms)

                    zoomTry = zooms(zz);
                    mapType = mapTypes(mt);

                    % Build the Google Static Maps URL for this candidate
                    % map configuration.
                    baseUrl = "https://maps.googleapis.com/maps/api/staticmap";
                    url = baseUrl + ...
                        "?center=" + centerLat + "," + centerLon + ...
                        "&zoom=" + zoomTry + ...
                        "&size=" + mapW + "x" + mapH + ...
                        "&scale=" + scale + ...
                        "&maptype=" + mapType + ...
                        "&key=" + string(cfg.apiKey);

                    fprintf("\nTrying zoom=%d mapType=%s tform=%s\n", zoomTry, mapType, tforms(tf));

                    % Download the candidate Google map image. If the
                    % download fails, skip this configuration and try another.
                    try
                        websave("google_map_tmp.png", url);
                        I_map = imread("google_map_tmp.png");
                    catch
                        fprintf("  -> map download/read failed, skipping\n");
                        continue;
                    end

                    % Ensure the map is RGB.
                    if size(I_map,3)==1, I_map = repmat(I_map,[1 1 3]); end

                    % Resize the screenshot and mask to match the Google map
                    % dimensions. This allows feature matching and warping to
                    % operate in the same image coordinate frame.
                    I_snap_rs = imresize(I_snap, [size(I_map,1) size(I_map,2)]);
                    mask_rs   = imresize(mask_snap, [size(I_map,1) size(I_map,2)], "nearest");

                    % Convert both images to smoothed grayscale images before
                    % feature detection. Smoothing reduces noise and improves
                    % the robustness of feature matching.
                    G_map  = imgaussfilt(im2gray(I_map), 1);
                    G_snap = imgaussfilt(im2gray(I_snap_rs), 1);

                    % Detect KAZE image features in both images. These are
                    % visually distinctive points used to estimate how the
                    % screenshot maps onto the Google map.
                    ptsMap  = detectKAZEFeatures(G_map);
                    ptsSnap = detectKAZEFeatures(G_snap);

                    % If either image has too few features, registration will
                    % not be reliable.
                    if ptsMap.Count < 20 || ptsSnap.Count < 20
                        fprintf("  -> too few KAZE points\n");
                        continue;
                    end

                    % Extract feature descriptors at the detected points.
                    [featMap,  vMap]  = extractFeatures(G_map,  ptsMap);
                    [featSnap, vSnap] = extractFeatures(G_snap, ptsSnap);

                    % Match screenshot features to map features. The matching
                    % settings favor unique, relatively confident matches.
                    pairs = matchFeatures(featSnap, featMap, 'Unique', true, ...
                        'MaxRatio', 0.8, 'MatchThreshold', 80);

                    % Require enough matched feature pairs to estimate a
                    % meaningful geometric transformation.
                    if isempty(pairs) || size(pairs,1) < 20
                        fprintf("  -> too few matches (%d)\n", size(pairs,1));
                        continue;
                    end

                    % Pull the matched feature locations from the screenshot
                    % and map images.
                    mSnap = vSnap(pairs(:,1));
                    mMap  = vMap(pairs(:,2));

                    % Estimate the transformation that maps screenshot
                    % coordinates into Google map coordinates.
                    try
                        [tformEst, inlierIdx, status] = estimateGeometricTransform2D( ...
                            mSnap, mMap, tforms(tf), ...
                            "MaxNumTrials", 30000, ...
                            "Confidence", 99.5, ...
                            "MaxDistance", 10);
                    catch
                        fprintf("  -> transform estimation failed, skipping\n");
                        continue;
                    end

                    % Count the number of inlier matches. Inliers are matched
                    % points that agree with the estimated transformation.
                    if islogical(inlierIdx), nIn = nnz(inlierIdx); else, nIn = numel(inlierIdx); end
                    fprintf("  Inliers: %d (status=%d)\n", nIn, status);

                    % Save this alignment if it is the best one found so far.
                    if nIn > best.nInliers
                        best.nInliers = nIn;
                        best.tform    = tformEst;
                        best.I_map    = I_map;
                        best.zoom     = zoomTry;
                        best.mapType  = mapType;
                        best.mask_rs  = mask_rs;
                        best.Rfixed   = imref2d(size(I_map));
                        best.I_snap_rs = I_snap_rs;
                    end

                    % If the current alignment is good enough, stop searching
                    % within the current loop level.
                    if nIn >= minInliersAccept
                        fprintf("  -> accepted (>= %d inliers)\n", minInliersAccept);
                        break;
                    end
                end

                % Exit the zoom loop if a good registration has been found.
                if best.nInliers >= minInliersAccept, break; end
            end

            % Exit the map-type loop if a good registration has been found.
            if best.nInliers >= minInliersAccept, break; end
        end

        % If none of the tested configurations produced enough inliers, the
        % screenshot could not be reliably aligned to the Google map.
        if best.nInliers < minInliersAccept
            error("Registration failed: best inliers = %d (need >= %d).", ...
                  best.nInliers, minInliersAccept);
        end

        fprintf("\nBEST: inliers=%d zoom=%d mapType=%s\n", best.nInliers, best.zoom, best.mapType);

        % Use the best map and zoom level for all downstream calculations.
        I_map = best.I_map;
        zoom  = best.zoom;

%% ---------------- 4) WARP MASK ONTO MAP ----------------
        % Apply the estimated image transformation to the fire mask. This
        % moves the detected fire region from screenshot coordinates into
        % Google map coordinates.
        mask_warp = imwarp(best.mask_rs, best.tform, "OutputView", best.Rfixed, "Interp", "nearest");
        mask_warp = logical(mask_warp);

        % Save the aligned binary mask as an image file.
        imwrite(uint8(mask_warp)*255, outMask);
        fprintf("Saved warped mask: %s\n", outMask);

%% ---------------- 5) OVERLAY ----------------
        % Create a visual overlay by drawing the aligned fire mask on top of
        % the Google map. This provides a quick quality check for alignment.
        I_overlay = I_map;

        % Make sure the mask and map are the same image size before blending.
        if ~isequal(size(mask_warp,1), size(I_overlay,1)) || ~isequal(size(mask_warp,2), size(I_overlay,2))
            mask_warp = imresize(mask_warp, [size(I_overlay,1) size(I_overlay,2)], "nearest");
        end

        % Blend the fire mask into the map using a semi-transparent red color.
        alpha = 0.35;
        overlayColor = [255 0 0];
        for c = 1:3
            tmp = double(I_overlay(:,:,c));
            tmp(mask_warp) = (1-alpha)*tmp(mask_warp) + alpha*overlayColor(c);
            I_overlay(:,:,c) = uint8(tmp);
        end

        % Save the overlay preview.
        imwrite(I_overlay, outOverlay);
        fprintf("Saved overlay preview: %s\n", outOverlay);

%% ---------------- 6) BOUNDARY -> LAT/LON ----------------
        % Extract the boundary of the aligned fire mask. This boundary is
        % still in image pixel coordinates at this stage.
        B = bwboundaries(mask_warp, 'noholes');
        if isempty(B), error("Warped mask empty after alignment."); end

        % If multiple boundaries exist, use the largest one as the main fire
        % perimeter or burn-scar region.
        lens = cellfun(@(x) size(x,1), B);
        [~, iBig] = max(lens);
        boundary = B{iBig};

        % Separate the boundary into row and column pixel coordinates.
        yPix = boundary(:,1);
        xPix = boundary(:,2);

        % Get the aligned map dimensions.
        W = size(I_map,2);
        Himg = size(I_map,1);

        % Build latitude and longitude grids for every pixel in the Google
        % map image, then sample those grids at the boundary pixels.
        [latGrid, lonGrid] = pixelGridToLatLon(W, Himg, centerLat, centerLon, zoom, scale);
        latPoly = latGrid(sub2ind(size(latGrid), yPix, xPix));
        lonPoly = lonGrid(sub2ind(size(lonGrid), yPix, xPix));

        % Downsample the polygon points to reduce file size and simplify the
        % exported CSV/KML boundary.
        latPoly = latPoly(1:5:end);
        lonPoly = lonPoly(1:5:end);

        % Close the polygon if the first and last points are not already the
        % same. A closed polygon is needed for area estimation.
        if latPoly(1) ~= latPoly(end) || lonPoly(1) ~= lonPoly(end)
            latA = [latPoly(:); latPoly(1)];
            lonA = [lonPoly(:); lonPoly(1)];
        else
            latA = latPoly(:);
            lonA = lonPoly(:);
        end

        % Estimate the fire area. The latitude/longitude polygon is projected
        % into the appropriate UTM zone, then MATLAB's polyarea function is
        % used to compute the area in square meters.
        try
            % Use the mean polygon location to determine the UTM zone.
            lat0 = mean(latA); 
            lon0 = mean(lonA);
            utmZone = floor((lon0 + 180)/6) + 1;

            % EPSG codes 326xx are northern hemisphere UTM zones, while
            % EPSG codes 327xx are southern hemisphere UTM zones.
            if lat0 >= 0
                epsgCode = 32600 + utmZone;
            else
                epsgCode = 32700 + utmZone;
            end

            % Project geographic coordinates to planar UTM coordinates.
            crs = projcrs(epsgCode);
            [x, y] = projfwd(crs, latA, lonA);

            % Compute polygon area and convert from square meters to acres.
            area_m2 = abs(polyarea(x, y));
            area_acres = area_m2 * 0.000247105381;

            fprintf("\n--- Estimated Fire Area ---\n");
            fprintf("Projected CRS EPSG: %d (UTM zone %d)\n", epsgCode, utmZone);
            fprintf("Area = %.3e m^2\n", area_m2);
            fprintf("Area = %.1f acres\n\n", area_acres);

        catch ME
            % If projection or area estimation fails, the rest of the script
            % can still continue, but area-dependent outputs may be NaN.
            warning("Area calculation failed:\n%s", ME.message);
        end

        % Save the extracted fire boundary as a latitude/longitude table.
        Ttbl = table(latPoly(:), lonPoly(:), 'VariableNames', {'lat','lon'});
        writetable(Ttbl, outCSV);
        fprintf("Saved lat/lon CSV: %s\n", outCSV);

        % Save the same boundary as a KML polygon so it can be viewed in
        % Google Earth or other GIS tools.
        writeKMLPolygon(outKML, latPoly, lonPoly, sprintf('%s Fire Perimeter', char(scenario)));
        fprintf("Saved KML: %s\n", outKML);

%% ---------------- 7) DISPLAY ALIGNMENT ----------------
        % If figure generation is enabled, show the final aligned fire
        % perimeter on top of the Google map. This gives a quick visual check
        % that the image registration and mask warping worked correctly.
        if cfg.doFigures
            figure('Name','Alignment Overlay','Color','w');
            imshow(I_overlay); hold on;

            % Plot the extracted fire boundary in yellow on top of the map.
            plot(xPix, yPix, 'y-', 'LineWidth', 2);

            % Label the figure using the selected wildfire scenario.
            title(sprintf('%s Perimeter Over Google Maps', scenario));
        end

%% ---------------- 8) FIRE SPREAD SIM ----------------
        % Set up the options structure used by the fire-spread simulation.
        % These options control wind direction, directional spread behavior,
        % visual transparency, moisture effects, elevation effects, and GIF
        % creation.
        opts = struct();

        % Wind direction assumption, measured in degrees. This is passed to
        % the spread model to bias propagation direction.
        opts.windDirFromDeg = 45;

        % Anisotropy controls how strongly the fire spread favors the wind
        % direction instead of spreading equally in all directions.
        opts.anisotropy = 2.5;

        % Alpha controls transparency for plotted fire overlays.
        opts.alpha = 0.35;

        % Patchiness controls random gaps or discontinuities in spread. A
        % value of zero disables patchiness.
        opts.patchiness = 0;

        % Enable moisture effects in the spread model. Higher moisture cost
        % makes spread slower through wetter regions.
        opts.useMoisture = true;
        opts.moistureWeight = 1.5;

        % Elevation effects are disabled here, but the fields are included so
        % the spread functions can accept a consistent options structure.
        opts.useElevation = false;
        opts.elevGrid = [];

        % GIF settings. The helper function returns a frame-writing function
        % that the spread simulation can call during animation.
        opts.saveGif = logical(cfg.saveGif);
        opts.gifFile = char(string(cfg.gifFile));
        opts.gifDelayTime = cfg.gifDelayTime;
        opts.gifWriteFrame = make_gif_frame_writer(opts.gifFile, opts.gifDelayTime);

        % Total number of days over which the fire grows to the extracted or
        % calibrated perimeter.
        daysTotal = cfg.dayPerimeter;

        % Select the fire-spread routine and spread-rate assumptions based on
        % the scenario. Different scenarios can use different frame rates and
        % rate schedules because they represent different wildfire contexts.
        switch scenario
            case "Butte County"

                % Use a 6-hour plotting/animation step for the Butte case.
                opts.frameStepHours = 6;

                % Make sure the required Butte/general spread function exists
                % before calling it.
                if exist('simulate_fire_overlay_on_map','file') ~= 2
                    warning("simulate_fire_overlay_on_map.m not found on path. Returning alignment outputs only.");
                    outFire = [];
                else
                    % Run the spread model using the aligned map, geographic
                    % grids, fire perimeter, ignition point, and options.
                    outFire = simulate_fire_overlay_on_map( ...
                        I_map, latGrid, lonGrid, latPoly, lonPoly, ignLat, ignLon, daysTotal, opts);
                end

            case "Etosha National Park"

                % Use a finer 3-hour frame step for Etosha.
                opts.frameStepHours = 3;

                % Scenario-specific spread-rate schedule. The first column is
                % elapsed time in hours, and the second column is the assumed
                % spread-rate parameter used by the Etosha spread model.
                opts.rateSchedule = [
                    12,             2.6;
                    24,             1.9;
                    48,             1.4;
                    72,             1.0;
                    120,            0.45;
                    24*daysTotal,   0.12
                ];

                % Make sure the Etosha-specific spread function exists before
                % calling it.
                if exist('simulate_fire_overlay_on_map_etosha','file') ~= 2
                    warning("simulate_fire_overlay_on_map_etosha.m not found on path. Returning alignment outputs only.");
                    outFire = [];
                else
                    % Run the Etosha spread model.
                    outFire = simulate_fire_overlay_on_map_etosha( ...
                        I_map, latGrid, lonGrid, latPoly, lonPoly, ignLat, ignLon, daysTotal, opts);
                end

            case "US/Canadian Wildfires"

                % Use a 6-hour frame step for the US/Canada wildfire case.
                opts.frameStepHours = 6;

                % Scenario-specific spread-rate schedule. The first column is
                % elapsed time in hours, and the second column is the assumed
                % spread-rate parameter.
                opts.rateSchedule = [
                    12,           5.0;
                    24,           3.5;
                    72,           1.6;
                    120,          0.8;
                    24*daysTotal, 0.25
                ];

                % This case currently uses the general spread routine.
                if exist('simulate_fire_overlay_on_map','file') ~= 2
                    warning("simulate_fire_overlay_on_map.m not found on path. Returning alignment outputs only.");
                    outFire = [];
                else
                    % Run the fire-spread simulation.
                    outFire = simulate_fire_overlay_on_map( ...
                        I_map, latGrid, lonGrid, latPoly, lonPoly, ignLat, ignLon, daysTotal, opts);
                end

            otherwise

                % Fallback behavior for any scenario not explicitly handled
                % above.
                if exist('simulate_fire_overlay_on_map','file') ~= 2
                    warning("simulate_fire_overlay_on_map.m not found on path. Returning alignment outputs only.");
                    outFire = [];
                else
                    % Run the Canada-specific spread model if an unrecognized
                    % scenario reaches this fallback branch.
                    outFire = simulate_fire_overlay_on_map_canada( ...
                        I_map, latGrid, lonGrid, latPoly, lonPoly, ignLat, ignLon, daysTotal, opts);
                end
        end
    end

%% ---------------- 9) DELAY CASE SETUP ----------------
    % This section sets up the fire size at the start of suppression, applies
    % detection/coordination delay cases, runs post-detection suppression,
    % and stores the resulting performance metrics.

    % Initialize the nominal fire area at the perimeter day. This value is
    % later adjusted for detection or coordination delays.
    A0_nominal = NaN;

    % Use an explicit nominal area override if one was provided.
    if ~isnan(cfg.A0_nominal_override_acres) && cfg.A0_nominal_override_acres > 0
        A0_nominal = cfg.A0_nominal_override_acres;

    % Otherwise, use the last value from the simulated fire growth curve.
    elseif ~isempty(outFire) && isfield(outFire,'areaAcres') && ~isempty(outFire.areaAcres)
        A0_nominal = outFire.areaAcres(end);

    % If no growth curve exists, fall back to the area estimated directly
    % from the aligned perimeter.
    elseif ~isnan(area_acres)
        A0_nominal = area_acres;
    end

    % Estimate how quickly the fire is growing near the early part of the
    % growth curve. This slope is used to approximate how much additional
    % area is burned when detection or coordination is delayed.
    delaySlopeAcresPerDay = estimate_delay_slope_acres_per_day(outFire, cfg);

    % If the slope cannot be estimated from the growth curve, use the
    % user-provided fallback value from cfg.
    if isnan(delaySlopeAcresPerDay) && isfield(cfg,'delaySlopeAcresPerDay') && ~isnan(cfg.delaySlopeAcresPerDay)
        delaySlopeAcresPerDay = cfg.delaySlopeAcresPerDay;
    end

    % Store the delay growth slope in the output structure.
    perf.delaySlopeAcresPerDay = delaySlopeAcresPerDay;

    % Build the list of delay cases and labels from cfg. This may be a single
    % delay case or a vector of delay cases.
    [delayDaysList, delayLabels] = get_delay_cases(cfg);

    % If no delay cases were provided, run a default no-delay case.
    if isempty(delayDaysList)
        delayDaysList = 0;
        delayLabels   = "No delay";
    end

    % Convert the architecture resources into suppression assets. This is
    % only done if suppression plotting/modeling is enabled and the nominal
    % fire area is valid.
    assets = [];
    if cfg.plotSuppression && ~isnan(A0_nominal) && A0_nominal > 0
        assets = build_assets_from_resources(resources);
    end

    % Number of delay cases to simulate.
    nCases = numel(delayDaysList);

    % Preallocate the delay-case structure array. Each entry stores the
    % complete growth, suppression, AUC, CO2, and resolution-time results for
    % one delay case.
    delayCases = repmat(struct( ...
        'label', "", ...
        'delayDays', NaN, ...
        'suppressionStartDay', NaN, ...
        'A0_delayed_acres', NaN, ...
        'CO2_est_millionMetricTons', NaN, ...
        'CO2_est_method', "", ...
        'resolvedDayAbs', NaN, ...
        'resolvedDaysAfterSuppression', NaN, ...
        'AUC_pre_acreDays', NaN, ...
        'AUC_post_acreDays', NaN, ...
        'AUC_total_acreDays', NaN, ...
        'tPreDays', [], ...
        'aPreAcres', [], ...
        'tPostDays', [], ...
        'tAbsDays', [], ...
        'remNatural', [], ...
        'burnPost', [], ...
        'pulseByType', [], ...
        'pulseNames', strings(0,1), ...
        'cumSuppTotal', []), nCases, 1);

    % Loop through every delay case and compute the corresponding fire
    % growth, suppression response, burn burden, and emissions estimate.
    for ic = 1:nCases

        % Ensure delay is nonnegative and get the label for this case.
        dDays = max(0, delayDaysList(ic));
        lbl   = string(delayLabels(ic));

        % Build the fire-growth curve up to the time suppression begins.
        % This accounts for any added delay after the nominal perimeter day.
        [tPreCase, aPreCase, A0_case] = build_growth_to_suppression_start( ...
            outFire, cfg, dDays, A0_nominal, delaySlopeAcresPerDay);

        % Suppression begins at the end of the delayed growth curve.
        startDay = tPreCase(end);

        % Simulate the post-suppression fire trajectory using natural decay
        % and any architecture-defined suppression assets.
        caseRes = simulate_post_case(A0_case, startDay, cfg, assets);

        % Compute the pre-suppression burn burden using area under the
        % burn-area curve.
        AUC_pre = trapz(tPreCase, aPreCase);

        % Estimate CO2 emissions from the delayed burned area.
        [co2_est_mmt, co2_method] = estimate_co2_from_area_interp(A0_case);

        % Store identifying information and delay-specific initial area.
        delayCases(ic).label = lbl;
        delayCases(ic).delayDays = dDays;
        delayCases(ic).suppressionStartDay = startDay;
        delayCases(ic).A0_delayed_acres = A0_case;
        delayCases(ic).CO2_est_millionMetricTons = co2_est_mmt;
        delayCases(ic).CO2_est_method = co2_method;

        % Store burn burden before suppression, after suppression, and total.
        delayCases(ic).AUC_pre_acreDays = AUC_pre;
        delayCases(ic).AUC_post_acreDays = caseRes.AUC_post_acreDays;
        delayCases(ic).AUC_total_acreDays = AUC_pre + caseRes.AUC_post_acreDays;

        % Store the pre-suppression growth curve.
        delayCases(ic).tPreDays = tPreCase;
        delayCases(ic).aPreAcres = aPreCase;

        % Store the post-suppression results.
        delayCases(ic).resolvedDayAbs = caseRes.resolvedDayAbs;
        delayCases(ic).resolvedDaysAfterSuppression = caseRes.resolvedDaysAfterSuppression;
        delayCases(ic).tPostDays = caseRes.tPostDays;
        delayCases(ic).tAbsDays = caseRes.tAbsDays;
        delayCases(ic).remNatural = caseRes.remNatural;
        delayCases(ic).burnPost = caseRes.burnPost;
        delayCases(ic).pulseByType = caseRes.pulseByType;
        delayCases(ic).pulseNames = caseRes.pulseNames;
        delayCases(ic).cumSuppTotal = caseRes.cumSuppTotal;
    end

    % Store all delay cases in the main performance output.
    perf.delayCases = delayCases;

    % Use the first delay case as the primary output case. This keeps the
    % output structure simple for scripts that expect one main result, while
    % still preserving all cases in perf.delayCases.
    primary = delayCases(1);

    % Store core fire-size and delay metadata.
    perf.dayPerimeter = cfg.dayPerimeter;
    perf.A0_perimeterDay_acres = A0_nominal;
    perf.A0_delayed_acres = primary.A0_delayed_acres;
    perf.detectionDelayDays = primary.delayDays;

    % Store resolution-time metrics.
    perf.resolvedDayAbs = primary.resolvedDayAbs;
    perf.resolvedDaysAfterPerimeter = primary.resolvedDayAbs - primary.suppressionStartDay;
    perf.resolvedDaysAfterSuppression = primary.resolvedDaysAfterSuppression;

    % Store burn burden metrics. AUC represents area under the burn-area
    % curve in acre-days.
    perf.AUC_pre_acreDays   = primary.AUC_pre_acreDays;
    perf.AUC_post_acreDays  = primary.AUC_post_acreDays;
    perf.AUC_total_acreDays = primary.AUC_total_acreDays;

    % Store CO2 estimate for the primary case.
    perf.CO2_est_millionMetricTons = primary.CO2_est_millionMetricTons;
    perf.CO2_est_method = primary.CO2_est_method;
    perf.CO2_baseline_MMT = primary.CO2_est_millionMetricTons;

    % Store the post-suppression burn-area trajectory.
    perf.burnPost.tAbsDays  = primary.tAbsDays;
    perf.burnPost.areaAcres = primary.burnPost;

    % Store suppression pulse information so other scripts can inspect or
    % plot the asset-by-asset suppression behavior.
    perf.suppressionPulses.tPostDays    = primary.tPostDays;
    perf.suppressionPulses.tAbsDays     = primary.tAbsDays;
    perf.suppressionPulses.pulses       = primary.pulseByType;
    perf.suppressionPulses.names        = string(primary.pulseNames(:));
    perf.suppressionPulses.cumSuppAcres = primary.cumSuppTotal;

    % Store the nominal growth curve, if one exists. This allows sweep
    % scripts to reuse the curve later in fast mode.
    if ~isempty(outFire) && isfield(outFire,'tHours') && isfield(outFire,'areaAcres') ...
            && ~isempty(outFire.tHours) && ~isempty(outFire.areaAcres)
        perf.nominalGrowth_tDays     = outFire.tHours(:) / 24;
        perf.nominalGrowth_areaAcres = outFire.areaAcres(:);
    else
        perf.nominalGrowth_tDays     = [];
        perf.nominalGrowth_areaAcres = [];
    end

    % Pull the pre-suppression curve from the primary delay case.
    tPre = primary.tPreDays;
    aPre = primary.aPreAcres;

    % Build one continuous total burn-area curve that joins the
    % pre-suppression growth curve with the post-suppression decay curve.
    if ~isempty(primary.tAbsDays) && ~isempty(primary.burnPost)

        % If the final pre-suppression time equals the first post-suppression
        % time, remove the duplicate point before concatenating.
        if ~isempty(tPre) && abs(tPre(end) - primary.tAbsDays(1)) < 1e-12
            perf.tAbsDays_total  = [tPre; primary.tAbsDays(2:end)];
            perf.areaAcres_total = [aPre; primary.burnPost(2:end)];

        % If there is no duplicate boundary point, concatenate directly.
        else
            perf.tAbsDays_total  = [tPre; primary.tAbsDays];
            perf.areaAcres_total = [aPre; primary.burnPost];
        end

    % If no post-suppression curve exists, the total curve is just the
    % pre-suppression growth curve.
    else
        perf.tAbsDays_total  = tPre;
        perf.areaAcres_total = aPre;
    end
    %% ---------------- 10) PLOTS (ONLY in full mode) ----------------
    % Generate diagnostic plots only when figures are enabled, the model is
    % not in fast mode, and a valid nominal fire area exists.
    if cfg.doFigures && ~cfg.fastMode && ~isnan(A0_nominal) && A0_nominal > 0

        % Create a set of distinguishable colors for each delay case.
        colors = lines(max(nCases, 7));

        % Plot the full burn-area history, including fire growth and
        % post-suppression decay.
        figure('Name','Burn Area vs. Time (Growth + Suppression)','Color','w');
        hold on; grid on;

        % If a simulated growth curve exists, plot it from ignition to the
        % perimeter day.
        if ~isempty(outFire) && isfield(outFire,'tHours') && isfield(outFire,'areaAcres') && ~isempty(outFire.tHours)
            tGrowD = outFire.tHours(:)/24;
            aGrow  = outFire.areaAcres(:);
            hGrowth = plot(tGrowD, aGrow, 'Color', [0 0.4470 0.7410], 'LineWidth', 3);

        % If no growth curve exists, draw a simple fallback line using the
        % nominal burned area.
        else
            tGrowD = [0; cfg.dayPerimeter];
            aGrow  = [A0_nominal; A0_nominal];
            hGrowth = plot(tGrowD, aGrow, 'Color', [0 0.4470 0.7410], 'LineWidth', 3);
        end

        % Preallocate plot handles and labels for the delay-case legend.
        caseHandles = gobjects(nCases,1);
        caseNames   = strings(nCases,1);

        % Plot each delay case. Each case has a pre-suppression growth
        % portion, a post-suppression burn-area decay curve, and a marker
        % showing when suppression begins.
        for ic = 1:nCases
            C = colors(ic,:);
            dCase = delayCases(ic);
        
            % Plot fire growth up to the delayed suppression start. This
            % line is hidden from the legend to avoid duplicate entries.
            plot(dCase.tPreDays, dCase.aPreAcres, '-', ...
                'Color', C, 'LineWidth', 1.8, 'HandleVisibility','off');
        
            % Plot the post-suppression trajectory. This shows the remaining
            % active burn area after natural decay and suppression are applied.
            caseHandles(ic) = plot(dCase.tAbsDays, dCase.burnPost, '-', ...
                'Color', C, 'LineWidth', 2.2);
        
            % Mark the start of suppression for this delay case.
            scatter(dCase.suppressionStartDay, dCase.A0_delayed_acres, 36, ...
                'MarkerFaceColor', C, 'MarkerEdgeColor', 'k', ...
                'HandleVisibility','off');
        
            % Build a descriptive legend label showing delay case name,
            % burned area at suppression start, and suppression start time.
            caseNames(ic) = string(dCase.label) + ...
                " | A_0 = " + sprintf('%.0f', dCase.A0_delayed_acres) + ...
                " ac | t_s = " + sprintf('%.2f', dCase.suppressionStartDay) + " d";
        end

        % Draw a vertical reference line at the nominal perimeter day.
        hx = xline(cfg.dayPerimeter, '--k', sprintf('Day %.2f perimeter', cfg.dayPerimeter), ...
            'LabelOrientation','aligned', ...
            'LabelVerticalAlignment','bottom');

        % Keep the perimeter-day line out of the legend.
        hx.Annotation.LegendInformation.IconDisplayStyle = 'off';

        % Add axis labels and title.
        ylabel('Burn Area [Acres]');
        xlabel('Time [Days]');
        title('Burn Area vs. Time (Growth + Detection Delay Cases)');

        % Set the x-axis to include all resolved cases, with a small margin.
        allResolved = [delayCases.resolvedDayAbs];
        allResolved = allResolved(isfinite(allResolved));
        if ~isempty(allResolved)
            xlim([0 max(allResolved) + 0.25]);
        end

        % Add a legend containing the nominal growth curve and each delay
        % case trajectory.
        legend([hGrowth; caseHandles], ["Burn growth (to perimeter)"; caseNames], ...
            'Location','northeastoutside');

        % If suppression pulse data exist, create a second plot showing the
        % first 12 hours of suppression activity for the primary delay case.
        if ~isempty(primary.pulseByType)

            % Create a zoomed suppression-pulse figure.
            figure('Name','Suppression Pulses (Zoomed 12 Hours)','Color','w');
            hold on; grid on;

            % Define the 12-hour window after suppression begins.
            t0 = primary.suppressionStartDay;
            t1 = primary.suppressionStartDay + 12/24;

            % Select only the time points inside the 12-hour window.
            idxWin = (primary.tAbsDays >= t0) & (primary.tAbsDays <= t1);
            tWin = primary.tAbsDays(idxWin);

            % Determine how many asset types have pulse trains.
            K = size(primary.pulseByType,2);

            % Store dummy plot handles and labels for the legend.
            pulseHandles2 = gobjects(0,1);
            pulseNames2   = strings(0,1);

            % Create colors for each suppression asset type.
            C2 = lines(max(K,7));

            % Loop through each suppression asset type.
            for ii = 1:K

                % Extract the pulse train for this asset type inside the
                % selected 12-hour window.
                y = primary.pulseByType(idxWin,ii);

                % Find each time step where this asset contributes
                % suppression capacity.
                idxEv = find(y > 0);
                if isempty(idxEv), continue; end

                % Plot each suppression event as a vertical pulse.
                for kEv = 1:numel(idxEv)
                    x = tWin(idxEv(kEv));
                    val = y(idxEv(kEv));
                    plot([x x], [0 val], '-', 'LineWidth', 1.2, 'Color', C2(ii,:));
                end

                % Add an invisible/dummy line so this asset type appears once
                % in the legend.
                pulseHandles2(end+1,1) = plot(NaN, NaN, '-', 'LineWidth', 1.2, 'Color', C2(ii,:));
                pulseNames2(end+1,1)   = string(primary.pulseNames(ii));
            end

            % Label the suppression-pulse plot.
            xlabel('Time [Days]');
            ylabel('Suppression per Use [Acres/use]');
            title(sprintf('Suppression Pulse Trains (First 12 Hours After Day %.2f)', primary.suppressionStartDay));

            % Limit the plot to the first 12 hours and a readable suppression
            % capacity range.
            ylim([0 50]);
            xlim([t0 t1]);

            % Add a legend if any pulse handles were created.
            if ~isempty(pulseHandles2)
                legend(pulseHandles2, pulseNames2, 'Location','northeastoutside');
            end
        end
    end

    %% ---------------- 10B) CO2 FIGURE ----------------
    % Generate a CO2 estimation figure only in full mode with a valid nominal
    % fire area.
    if cfg.doFigures && ~cfg.fastMode && ~isnan(A0_nominal) && A0_nominal > 0

        % Load the wildfire emissions training data. This provides historical
        % burned-area and CO2 values used to estimate emissions for the model.
        [~, acresData, co2Data_mmt] = co2_training_data_2021();

        % Sort the training data by burned area so the plotted curve is clean.
        [acresS, idxS] = sort(acresData(:));
        co2S = co2Data_mmt(idxS);

        % Use only positive burned-area and emissions values for the log-log
        % fit.
        x = acresS; 
        y = co2S;
        keep = (x > 0) & (y > 0);

        % Fit a power-law relationship between burned area and emissions:
        % CO2 = a * acres^b.
        %
        % If robustfit is available, use it to reduce the influence of
        % outliers. Otherwise, use a standard polynomial fit in log space.
        useRobust = exist('robustfit','file') == 2;
        if useRobust
            beta = robustfit(log(x(keep)), log(y(keep)));
            loga = beta(1); 
            b = beta(2);
        else
            p = polyfit(log(x(keep)), log(y(keep)), 1);
            b = p(1); 
            loga = p(2);
        end

        % Convert the fitted intercept back from log space.
        a = exp(loga);

        % Evaluate the fitted power-law curve across the observed burned-area
        % range.
        xFit = linspace(min(x), max(x), 400).';
        yFit = a .* (xFit.^b);

        % Create the CO2 figure and axes.
        figCO2 = figure('Name','CO2 Emissions vs Burned Area (Estimate)','Color','w');
        axCO2  = axes(figCO2);
        hold(axCO2,'on'); grid(axCO2,'on'); box(axCO2,'on');

        % Plot the historical wildfire data and the fitted power-law curve.
        h1 = scatter(axCO2, acresS, co2S, 45, 'filled', 'DisplayName','2021 Fires');
        h2 = plot(axCO2, xFit, yFit, '-', 'LineWidth', 2.2, 'DisplayName','Power-Law Fit');

        % Prepare plot handles and labels for each modeled delay case.
        colors = lines(max(nCases, 7));
        hCaseCO2 = gobjects(nCases,1);
        labCaseCO2 = strings(nCases,1);

        % Plot each delay case on the CO2 curve.
        for ic = 1:nCases

            % Extract modeled burned area and estimated CO2 emissions for the
            % current delay case.
            xB = delayCases(ic).A0_delayed_acres;
            yB = delayCases(ic).CO2_est_millionMetricTons;

            % Plot the modeled case as a highlighted marker.
            hCaseCO2(ic) = scatter(axCO2, xB, yB, 120, 'filled', ...
                'MarkerFaceColor', [0.85 0.65 0.1], ...
                'MarkerEdgeColor','k', 'LineWidth',1.0);

            % Build a legend label with the case name and emissions value.
            labCaseCO2(ic) = string(delayCases(ic).label) + ...
                " | " + sprintf('%.2f', yB) + " MMT";
        end

        % Label and title the CO2 plot.
        xlabel(axCO2,'Total Burned Area [acres]');
        ylabel(axCO2,'CO2 Emissions [million metric tons]');
        title(axCO2,'CO2 Emissions vs Burned Area');

        % Set axis limits so all historical data and modeled cases are shown
        % with some padding.
        xlim(axCO2, [0 max([acresS; [delayCases.A0_delayed_acres].']) * 1.10]);
        ylim(axCO2, [0 max([co2S; [delayCases.CO2_est_millionMetricTons].']) * 1.30]);

        % Add the historical data and model cases to the legend.
        legend(axCO2, [h1; hCaseCO2], ...
            ["2021 Fires"; labCaseCO2], ...
            'Location','northwest');
    end

    %% ---- Populate outputs ----
    % Store basic geographic and map information in the output structure.
    perf.ignLat = ignLat;
    perf.ignLon = ignLon;
    perf.zoom   = zoom;

    % Store the perimeter area estimated from the aligned fire mask.
    perf.perimeterAreaAcres = area_acres;

    % Full mode produces map/image/geospatial output files, so their paths
    % are stored in perf if they exist.
    if ~cfg.fastMode

        % Store the overlay image path if it exists.
        if exist('outOverlay','var')
            perf.outOverlay = outOverlay;
        else
            perf.outOverlay = "";
        end

        % Store the aligned mask image path if it exists.
        if exist('outMask','var')
            perf.outMask = outMask;
        else
            perf.outMask = "";
        end

        % Store the CSV boundary output path if it exists.
        if exist('outCSV','var')
            perf.outCSV = outCSV;
        else
            perf.outCSV = "";
        end

        % Store the KML boundary output path if it exists.
        if exist('outKML','var')
            perf.outKML = outKML;
        else
            perf.outKML = "";
        end

        % Store the number of days used to grow the fire to the perimeter.
        perf.daysTotal = cfg.dayPerimeter;

        % Store optional outputs from the fire-spread model if available.
        if ~isempty(outFire)

            % Some spread routines may report a target area.
            if isfield(outFire,'targetAcres')
                perf.targetAcres = outFire.targetAcres;
            else
                perf.targetAcres = NaN;
            end

            % Store the final simulated fire area from the growth curve.
            if isfield(outFire,'areaAcres') && ~isempty(outFire.areaAcres)
                perf.areaEndAcres = outFire.areaAcres(end);
            else
                perf.areaEndAcres = NaN;
            end

            % Store containment day if the spread model reports it.
            if isfield(outFire,'containedDay')
                perf.containedDay = outFire.containedDay;
            end

        % If no spread model output exists, set area outputs to NaN.
        else
            perf.targetAcres  = NaN;
            perf.areaEndAcres = NaN;
        end

    % Fast mode does not generate image/geospatial output files, so those
    % fields are set to empty strings or NaN for consistency.
    else
        perf.outOverlay = "";
        perf.outMask    = "";
        perf.outCSV     = "";
        perf.outKML     = "";
        perf.daysTotal  = cfg.dayPerimeter;
        perf.targetAcres  = NaN;
        perf.areaEndAcres = NaN;
    end
end

%% ========================= HELPERS =========================

function [latGrid, lonGrid] = pixelGridToLatLon(W, H, centerLat, centerLon, zoom, scale)
    % Convert every pixel in a Google Static Maps image to latitude and
    % longitude. The result is two grids, latGrid and lonGrid, where each
    % entry corresponds to one pixel in the map image.

    % Google Maps uses a Web Mercator tile system where the total world size
    % doubles with every zoom level.
    worldSize = 256 * 2^zoom;

    % Convert the map center from latitude/longitude to Google world-pixel
    % coordinates.
    [cx, cy] = latLonToWorld(centerLat, centerLon, worldSize);

    % Convert the displayed image width and height to unscaled Google map
    % pixels. The scale factor accounts for high-resolution map requests.
    Ww = W / scale;
    Hw = H / scale;

    % Compute the upper-left corner of the map in Google world coordinates.
    x0 = cx - Ww/2;
    y0 = cy - Hw/2;

    % Create pixel-coordinate grids for the image.
    [X, Y] = meshgrid(0:W-1, 0:H-1);

    % Convert image pixels to Google world coordinates.
    Xw = x0 + X/scale;
    Yw = y0 + Y/scale;

    % Convert Google world coordinates back to latitude and longitude.
    [latGrid, lonGrid] = worldToLatLon(Xw, Yw, worldSize);
end

function [xw, yw] = latLonToWorld(lat, lon, worldSize)
    % Convert latitude and longitude to Google Web Mercator world
    % coordinates.

    % Clamp latitude to the valid Web Mercator range. Values near the poles
    % cannot be represented in standard Google Maps projection.
    lat = max(min(lat, 85.05112878), -85.05112878);

    % Longitude maps linearly to the horizontal world coordinate.
    xw = (lon + 180) / 360 * worldSize;

    % Latitude maps nonlinearly to the vertical world coordinate through the
    % Mercator projection.
    sinLat = sind(lat);
    yw = (0.5 - log((1+sinLat)./(1-sinLat)) / (4*pi)) * worldSize;
end

function [lat, lon] = worldToLatLon(xw, yw, worldSize)
    % Convert Google Web Mercator world coordinates back to latitude and
    % longitude.

    % Recover longitude from the horizontal world coordinate.
    lon = (xw / worldSize) * 360 - 180;

    % Recover latitude by applying the inverse Web Mercator transform.
    n = pi - 2*pi*yw/worldSize;
    lat = atan(sinh(n)) * 180/pi;
end

function writeKMLPolygon(filename, lat, lon, nameStr)
    % Write a latitude/longitude polygon to a KML file. The resulting file
    % can be opened in Google Earth or other GIS software.

    % KML polygons must be closed. If the first and last points differ,
    % append the first point to the end of the coordinate list.
    if lat(1) ~= lat(end) || lon(1) ~= lon(end)
        lat(end+1) = lat(1); 
        lon(end+1) = lon(1);
    end

    % Open the output KML file for writing.
    fid = fopen(filename,'w');

    % Write the KML header and begin the document.
    fprintf(fid,'<?xml version="1.0" encoding="UTF-8"?>\n');
    fprintf(fid,'<kml xmlns="http://www.opengis.net/kml/2.2">\n');

    % Create a placemark with the provided polygon name.
    fprintf(fid,'  <Document><Placemark><name>%s</name>\n', nameStr);

    % Define simple styling for the polygon boundary. Fill is disabled so
    % the polygon appears as an outline.
    fprintf(fid,'  <Style><LineStyle><width>3</width></LineStyle><PolyStyle><fill>0</fill></PolyStyle></Style>\n');

    % Begin writing the polygon coordinates.
    fprintf(fid,'  <Polygon><outerBoundaryIs><LinearRing><coordinates>\n');

    % KML coordinate order is longitude, latitude, altitude.
    for i=1:numel(lat)
        fprintf(fid,'  %.8f,%.8f,0\n', lon(i), lat(i));
    end

    % Close the KML polygon and document.
    fprintf(fid,'  </coordinates></LinearRing></outerBoundaryIs></Polygon>\n');
    fprintf(fid,'  </Placemark></Document></kml>\n');

    % Close the file.
    fclose(fid);
end

%% ===== CO2 helpers =====

function [co2_est_mmt, methodStr] = estimate_co2_from_area_interp(area_acres)
    % Estimate CO2 emissions from burned area using interpolation of the
    % stored 2021 wildfire emissions dataset.

    % If the input area is invalid, return NaN and label the method as
    % invalid.
    if isnan(area_acres) || area_acres <= 0
        co2_est_mmt = NaN;
        methodStr = "invalid area";
        return;
    end

    % Load historical wildfire burned-area and CO2 data.
    [~, acresData, co2Data_mmt] = co2_training_data_2021();

    % Sort the data by burned area before interpolation.
    [acresS, idx] = sort(acresData(:));
    co2S = co2Data_mmt(idx);

    % Estimate emissions by linearly interpolating burned area to CO2.
    % Extrapolation is allowed for areas outside the training range.
    co2_est_mmt = interp1(acresS, co2S, area_acres, 'linear', 'extrap');

    % Prevent negative emissions if extrapolation produces a bad value.
    co2_est_mmt = max(0, co2_est_mmt);

    % Store a short description of the estimation method.
    methodStr = "interp1 linear (acres->CO2) extrap";
end

function [fireNames, acres, co2_mmt] = co2_training_data_2021()
    % Historical wildfire emissions dataset used for the CO2 estimate.
    % fireNames contains the wildfire names, acres contains burned area, and
    % co2_mmt contains estimated CO2 emissions in million metric tons.

    fireNames = string([ ...
        "Dixie"; "Monument"; "Caldor"; "River Complex"; "Antelope"; ...
        "McFarland"; "Windy"; "Sugar"; "McCash"; "KNP Complex"; ...
        "Tamarack"; "French"; "Lava"; "Alisal"; "Salt"; ...
        "Tennant"; "River"; "Walkers"; "Fawn"; "Southern" ]);

    % Burned area for each wildfire in acres.
    acres = [ ...
        934564; 220888; 215733; 195464; 135404; ...
        120140;  96816;  96776;  94248;  86095; ...
         49607;  26227;  22336;  16332;  12487; ...
         10324;   9623;   8464;   8413;   5188 ];

    % Estimated CO2 emissions for each wildfire in million metric tons.
    co2_mmt = [ ...
        37.4; 4.7; 9.9; 8.3; 3.8; ...
         3.6; 3.2; 3.6; 2.4; 3.0; ...
         1.5; 0.9; 0.6; 0.2; 0.3; ...
         0.2; 0.2; 0.1; 0.2; 0.05 ];
end

%% ===== Delay helpers =====

function [delayDaysList, delayLabels] = get_delay_cases(cfg)
    % Build the list of detection or coordination delay cases that the model
    % will simulate.

    % If a full delay list is provided, use it directly.
    if isfield(cfg,'detectionDelayDaysList') && ~isempty(cfg.detectionDelayDaysList)
        delayDaysList = cfg.detectionDelayDaysList(:);
        delayLabels = string(cfg.detectionDelayLabels(:));

        % If labels are missing or do not match the number of delay cases,
        % automatically create labels based on delay duration in hours.
        if isempty(delayLabels) || numel(delayLabels) ~= numel(delayDaysList)
            delayLabels = strings(numel(delayDaysList),1);
            for i = 1:numel(delayDaysList)
                delayLabels(i) = "Delay " + sprintf('%.2f h', 24*delayDaysList(i));
            end
        end

    % Otherwise, use the single scalar delay value.
    else
        delayDaysList = max(0, cfg.detectionDelayDays);
        delayLabels = "Butte Fire CO2 Emission Estimate";
    end

    % Force the delay list to be a numeric column vector.
    delayDaysList = double(delayDaysList(:));

    % Replace invalid or negative delay values with zero.
    delayDaysList(~isfinite(delayDaysList) | delayDaysList < 0) = 0;

    % Force labels to be a string column vector.
    delayLabels = string(delayLabels(:));
end

function slopeAcresPerDay = estimate_delay_slope_acres_per_day(outFire, cfg)
%ESTIMATE_DELAY_SLOPE_ACRES_PER_DAY
% Estimate an early-growth slope for the detection-delay penalty.
%
% This function uses the first few nonzero points in the growth curve rather
% than the flat tail near the perimeter day. The resulting slope estimates
% how many additional acres may burn per day when detection or coordination
% is delayed.

    % Initialize the output as NaN. It will stay NaN if a valid slope cannot
    % be computed from the available fire-growth data.
    slopeAcresPerDay = NaN;

    % If the fire-growth output does not exist or does not contain the needed
    % fields, there is no curve from which to estimate a slope.
    if isempty(outFire) || ~isfield(outFire,'tHours') || ~isfield(outFire,'areaAcres')
        return;
    end

    % At least two points are required to calculate a slope.
    if numel(outFire.tHours) < 2 || numel(outFire.areaAcres) < 2
        return;
    end

    % Convert time from hours to days and force area into a column vector.
    tDays = outFire.tHours(:) / 24;
    a     = outFire.areaAcres(:);

    % Remove duplicate time entries while preserving the original order.
    [tDays, iu] = unique(tDays, 'stable');
    a = a(iu);

    % Keep only finite time and area values.
    keep = isfinite(tDays) & isfinite(a);
    tDays = tDays(keep);
    a     = a(keep);

    % Confirm that enough valid points remain after cleaning.
    if numel(tDays) < 2
        return;
    end

    % Find the first positive burned-area values. This avoids using an
    % initial flat region before growth begins.
    idxPos = find(a > 0);
    if numel(idxPos) < 2
        return;
    end

    % Use the first positive point and the next few points to approximate the
    % early growth rate.
    i1 = idxPos(1);
    i2 = min(numel(tDays), i1 + 3);

    t1 = tDays(i1);
    t2 = tDays(i2);
    a1 = a(i1);
    a2 = a(i2);

    % Compute acres per day if the selected times are distinct.
    if t2 > t1
        slopeAcresPerDay = (a2 - a1) / (t2 - t1);
    end

    % Reject negative or non-finite slopes.
    if ~isfinite(slopeAcresPerDay) || slopeAcresPerDay < 0
        slopeAcresPerDay = NaN;
    end
end

function caseRes = simulate_post_case(A0_case, startDay, cfg, assets)
    % Simulate the post-suppression fire trajectory for one delay case.
    %
    % The model starts with an active burn area A0_case at startDay. From
    % there, the remaining burned area decreases due to natural decay and,
    % if enabled, cumulative suppression pulses from available response
    % assets.

    % Convert the suppression time step from hours to days.
    dtH    = cfg.supp_dtHours;
    dtDays = dtH/24;

    % Preallocate the output structure with default values. These defaults
    % remain if the case cannot be simulated.
    caseRes = struct();
    caseRes.resolvedDayAbs = NaN;
    caseRes.resolvedDaysAfterSuppression = NaN;
    caseRes.AUC_post_acreDays = NaN;
    caseRes.tPostDays = [];
    caseRes.tAbsDays = [];
    caseRes.remNatural = [];
    caseRes.burnPost = [];
    caseRes.pulseByType = [];
    caseRes.pulseNames = strings(0,1);
    caseRes.cumSuppTotal = [];

    % If the delayed fire area is invalid, return the default empty result.
    if isnan(A0_case) || A0_case <= 0
        return;
    end

    % The initial simulation length comes from cfg. If the fire does not
    % resolve in that time, the while loop extends the horizon up to this hard
    % cap.
    maxExtraDaysHard = 365;
    tMax = cfg.supp_tMaxDays;
    resolvedIdx = [];

    % Keep extending the post-suppression time horizon until the fire
    % resolves or the hard cap is reached.
    while true

        % Time after suppression begins and corresponding absolute time.
        tPostDays = (0:dtDays:tMax).';
        tAbsDays  = startDay + tPostDays;

        % Natural decay model. The active burn area decays exponentially with
        % a half-life specified by cfg.naturalHalfLifeDays.
        halfLifeDays = max(0.1, cfg.naturalHalfLifeDays);
        k = log(2)/halfLifeDays;
        remNatural = A0_case .* exp(-k .* tPostDays);

        % Initialize suppression pulse arrays.
        cumSuppTotal = zeros(size(tPostDays));
        pulseByType  = [];
        pulseNames   = strings(0,1);

        % If suppression is enabled and assets exist, build the cumulative
        % suppression curve from asset pulse trains.
        if cfg.plotSuppression && ~isempty(assets)
            [pulseByType, pulseNames, cumSuppTotal] = build_pulse_trains(tPostDays, assets, dtDays);
        end

        % Remaining active burn area after natural decay and cumulative
        % suppression are applied. The area cannot go below zero.
        burnPost = max(remNatural - cumSuppTotal, 0);

        % The fire is considered resolved when remaining active burn area
        % reaches zero.
        resolvedIdx = find(burnPost <= 0, 1, 'first');

        % If the fire resolves, trim all arrays so the output ends exactly at
        % the resolution time.
        if ~isempty(resolvedIdx)
            tPostDays    = tPostDays(1:resolvedIdx);
            tAbsDays     = tAbsDays(1:resolvedIdx);
            remNatural   = remNatural(1:resolvedIdx);
            burnPost     = burnPost(1:resolvedIdx);
            cumSuppTotal = cumSuppTotal(1:resolvedIdx);

            if ~isempty(pulseByType)
                pulseByType = pulseByType(1:resolvedIdx,:);
            end
            break;
        end

        % If the hard cap is reached, stop extending the simulation.
        if tMax >= maxExtraDaysHard
            warning('Fire did not resolve by %.1f days after suppression start (hard cap reached).', tMax);
            break;
        end

        % Extend the simulation horizon and try again.
        tMax = min(tMax * 1.5, maxExtraDaysHard);
    end

    % Store resolution timing if the fire resolved.
    if ~isempty(resolvedIdx)
        caseRes.resolvedDayAbs = tAbsDays(end);
        caseRes.resolvedDaysAfterSuppression = tPostDays(end);
    end

    % Compute post-suppression burn burden as the area under the active
    % burn-area curve.
    if numel(tPostDays) >= 2
        caseRes.AUC_post_acreDays = trapz(tPostDays, burnPost);
    else
        caseRes.AUC_post_acreDays = NaN;
    end

    % Store all post-suppression time histories.
    caseRes.tPostDays = tPostDays;
    caseRes.tAbsDays = tAbsDays;
    caseRes.remNatural = remNatural;
    caseRes.burnPost = burnPost;
    caseRes.pulseByType = pulseByType;
    caseRes.pulseNames = pulseNames;
    caseRes.cumSuppTotal = cumSuppTotal;
end

function [tPreCase, aPreCase, A0_case] = build_growth_to_suppression_start( ...
    outFire, cfg, delayDays, A0_nominal, delaySlopeAcresPerDay)
    % Build the fire-growth curve from ignition to the time suppression
    % begins.
    %
    % For a no-delay case, this returns the active burn-area curve up to the
    % nominal perimeter day. For a delayed case, it extends and rescales the
    % curve to represent additional burned area caused by delayed detection or
    % coordination.

    % Delays cannot be negative.
    delayDays = max(0, delayDays);

    % Convert the model time step from hours to days. Use a fallback if the
    % supplied value is invalid.
    dtDays = cfg.supp_dtHours / 24;
    if ~isfinite(dtDays) || dtDays <= 0
        dtDays = 0.25 / 24;
    end

    % ----------------------------
    % Common pre-perimeter horizon
    % ----------------------------

    % The perimeter day is the time when the nominal fire reaches the
    % calibrated or extracted perimeter.
    tPerim = cfg.dayPerimeter;

    % Build a uniform time grid from ignition to the perimeter day.
    tBaseCase = (0:dtDays:tPerim).';

    % Ensure the final time exactly includes the perimeter day.
    if isempty(tBaseCase) || abs(tBaseCase(end) - tPerim) > 1e-12
        tBaseCase(end+1,1) = tPerim;
    end

    % Build the nominal growth reference. If a detailed fire-growth curve is
    % available, use it. Otherwise, fall back to a simple line from zero area
    % at ignition to A0_nominal at the perimeter day.
    if ~isempty(outFire) && isfield(outFire,'tHours') && isfield(outFire,'areaAcres') ...
            && ~isempty(outFire.tHours) && ~isempty(outFire.areaAcres)

        tBase = outFire.tHours(:) / 24;
        aBase = outFire.areaAcres(:);
    else
        tBase = [0; tPerim];
        aBase = [0; A0_nominal];
    end

    % Remove invalid time and area values.
    keep = isfinite(tBase) & isfinite(aBase);
    tBase = tBase(keep);
    aBase = aBase(keep);

    % If no valid growth reference remains, return a zero-area curve.
    if isempty(tBase) || isempty(aBase)
        tPreCase = tBaseCase;
        aPreCase = zeros(size(tPreCase));
        A0_case = 0;
        return;
    end

    % Remove duplicate time values before interpolation.
    [tBase, iu] = unique(tBase, 'stable');
    aBase = aBase(iu);

    % Make sure the curve starts at ignition time. If the supplied curve
    % starts later than zero, prepend a zero-area ignition point.
    if tBase(1) > 0
        tBase = [0; tBase];
        aBase = [0; aBase];
    end

    % Interpolate the nominal growth curve onto the common time grid. PCHIP
    % preserves a smooth, shape-respecting curve.
    aNomBase = interp1(tBase, aBase, tBaseCase, 'pchip', 'extrap');

    % Burned area cannot be negative.
    aNomBase = max(aNomBase, 0);

    % Set up early natural decay. This allows active burn area to decrease
    % before the formal suppression start if cfg.useEarlyNaturalDecay is true.
    if cfg.useEarlyNaturalDecay
        halfLifeDays = max(0.1, cfg.naturalHalfLifeDays);
        k = log(2) / halfLifeDays;
    else
        k = 0;
    end

    % -------------------------------------------------------
    % Step 1: build common pre-perimeter active-burn history
    % -------------------------------------------------------

    % Initialize active burned area using the interpolated nominal curve.
    aActiveBase = zeros(size(aNomBase));
    aActiveBase(1) = aNomBase(1);

    % Step through the nominal growth curve. At each time step, add new fire
    % growth and subtract natural decay if early decay is enabled.
    for i = 2:numel(tBaseCase)
        dt = tBaseCase(i) - tBaseCase(i-1);

        % Incremental growth from the nominal area curve.
        dGrow = max(0, aNomBase(i) - aNomBase(i-1));

        % Natural decay begins only after the configured decay start time.
        if cfg.useEarlyNaturalDecay && tBaseCase(i-1) >= cfg.naturalDecayStartDays
            dDecay = k * aActiveBase(i-1) * dt;
        else
            dDecay = 0;
        end

        % Update active area. The active burn area cannot go below zero.
        aActiveBase(i) = max(0, aActiveBase(i-1) + dGrow - dDecay);
    end

    % -------------------------------------------------------
    % Step 2: extend through the extra delay window smoothly
    % -------------------------------------------------------

    % If there is no delay, suppression begins at the perimeter day. Return
    % the active burn history directly.
    if delayDays <= 0
        tPreCase = tBaseCase;
        aPreCase = aActiveBase;
        A0_case  = aPreCase(end);
        return;
    end

    % Build the extra delay time grid after the perimeter day.
    tExt = (tPerim + dtDays : dtDays : tPerim + delayDays).';

    % Ensure the final delay time is included exactly.
    if isempty(tExt) || abs(tExt(end) - (tPerim + delayDays)) > 1e-12
        tExt(end+1,1) = tPerim + delayDays;
    end

    % Estimate two growth slopes: one during early growth and one near the
    % perimeter-day tail. These are blended to approximate added growth
    % during the delay period.
    [slopeEarly, slopeTail] = estimate_delay_slopes(outFire, cfg);

    % If the tail slope could not be estimated, approximate it from the last
    % two points in the nominal growth reference.
    if ~isfinite(slopeTail)
        if numel(tBase) >= 2
            slopeTail = (aBase(end) - aBase(max(1,end-1))) / ...
                        max(tBase(end) - tBase(max(1,end-1)), 1e-9);
        else
            slopeTail = 0;
        end
    end

    % If the early slope could not be estimated, use the supplied fallback
    % delay slope. If that is also unavailable, use the tail slope.
    if ~isfinite(slopeEarly)
        if isfinite(delaySlopeAcresPerDay) && delaySlopeAcresPerDay >= 0
            slopeEarly = delaySlopeAcresPerDay;
        else
            slopeEarly = slopeTail;
        end
    end

    % Blend early and tail growth slopes. A larger alpha emphasizes early
    % rapid growth, while a smaller alpha emphasizes the near-perimeter slope.
    alpha = 0.60;
    delaySlopeUse = max(0, alpha * slopeEarly + (1 - alpha) * slopeTail);

    % First compute the delayed endpoint after the perimeter day. This gives
    % an estimate of how large the fire would be after the delay window.
    aExt = zeros(size(tExt));
    aPrev = aActiveBase(end);
    tPrev = tPerim;

    for i = 1:numel(tExt)
        dt = tExt(i) - tPrev;

        % Add growth caused by the delay.
        dGrow = delaySlopeUse * dt;

        % Apply natural decay during the delay window, if enabled.
        if cfg.useEarlyNaturalDecay && tPrev >= cfg.naturalDecayStartDays
            dDecay = k * aPrev * dt;
        else
            dDecay = 0;
        end

        % Update delayed active area.
        aExt(i) = max(0, aPrev + dGrow - dDecay);

        aPrev = aExt(i);
        tPrev = tExt(i);
    end

    % Scale the whole pre-perimeter curve upward so the delayed case already
    % reflects increased severity before the perimeter-day marker.
    baseEnd = max(aActiveBase(end), 1e-9);
    delayedEnd = max(aExt(end), baseEnd);

    % Ratio between delayed endpoint and nominal perimeter-day endpoint.
    scaleFactor = delayedEnd / baseEnd;

    % Uniformly scale the active burn history.
    aActiveScaled = aActiveBase * scaleFactor;

    % Preserve zero ignition area if the original curve starts at zero.
    if abs(aActiveBase(1)) < 1e-12
        aActiveScaled(1) = 0;
    end

    % Re-anchor the post-perimeter extension so it starts from the scaled
    % pre-perimeter curve.
    aExt2 = zeros(size(tExt));
    aPrev = aActiveScaled(end);
    tPrev = tPerim;

    % Additional growth after the perimeter day is reduced because the delay
    % effect has already been represented by scaling the pre-perimeter curve.
    postPerimGrowthScale = 0.0;

    for i = 1:numel(tExt)
        dt = tExt(i) - tPrev;

        % Optional extra growth during the post-perimeter delay window.
        dGrow = postPerimGrowthScale * delaySlopeUse * dt;

        % Natural decay during the extension period.
        if cfg.useEarlyNaturalDecay && tPrev >= cfg.naturalDecayStartDays
            dDecay = k * aPrev * dt;
        else
            dDecay = 0;
        end

        % Update the delayed extension curve.
        aExt2(i) = max(0, aPrev + dGrow - dDecay);

        aPrev = aExt2(i);
        tPrev = tExt(i);
    end

    % Combine the scaled pre-perimeter curve and delayed extension into one
    % complete pre-suppression trajectory.
    tPreCase = [tBaseCase; tExt];
    aPreCase = [aActiveScaled; aExt2];

    % Fire area at suppression start.
    A0_case  = aPreCase(end);
end

%% ===== Suppression helpers =====

function assets = build_assets_from_resources(resources)
    % Convert the expanded architecture resource list into grouped
    % suppression assets used by the post-suppression fire model.

    % Pull the expanded element names from the resources structure.
    elems = getFieldAny(resources, {'expandedElements'}, string.empty);

    % If no elements exist, return an empty asset structure.
    if isempty(elems)
        assets = struct('name',{},'mult',{},'acresPerUse',{},'cycleDays',{},'startDelayDays',{});
        return;
    end

    % Force element names into a string column vector.
    elems = string(elems(:));

    % Pull suppression effectiveness values. These represent how many acres
    % each use of an asset can suppress.
    supp = getFieldAny(resources, {'expandedSuppVal','expandedSuppAcrePerUse','expandedSupp','expandedSuppAcph'}, []);
    if isempty(supp), supp = nan(size(elems)); else, supp = supp(:); end

    % Pull suppression cycle times. These represent how often an asset can
    % perform a suppression action.
    cycD = getFieldAny(resources, {'expandedCycleDays','expandedSuppIntervalDays','expandedIntervalDays'}, []);
    if isempty(cycD), cycD = nan(size(elems)); else, cycD = cycD(:); end

    % Keep only elements with positive suppression capability.
    keep = ~isnan(supp) & (supp > 0);
    elemsK = elems(keep);
    suppK  = supp(keep);
    cycK   = cycD(keep);

    % If no suppressing elements remain, return an empty asset structure.
    if isempty(elemsK)
        assets = struct('name',{},'mult',{},'acresPerUse',{},'cycleDays',{},'startDelayDays',{});
        return;
    end

    % Group repeated asset names together. This converts replicated elements
    % from the expanded architecture into one asset entry with multiplicity.
    [uNames,~,g] = unique(elemsK, 'stable');

    % Preallocate one asset structure for each unique suppressing asset type.
    assets = repmat(struct('name',"", 'mult',1, 'acresPerUse',0, 'cycleDays',1, 'startDelayDays',0), numel(uNames), 1);

    % Build each grouped asset entry.
    for i = 1:numel(uNames)
        nm = uNames(i);
        idx = (g == i);

        % Multiplicity is the number of repeated copies of this asset type.
        m = sum(idx);

        % Use the median suppression value and cycle time across repeated
        % copies. This is robust if the expanded list contains duplicate or
        % slightly varied values.
        S = median(suppK(idx), 'omitnan');
        T = median(cycK(idx),  'omitnan');

        % If no valid cycle time was supplied, use a default based on asset
        % type.
        if isnan(T) || T <= 0
            T = default_cycle_days(nm);
        end

        % Store the grouped asset properties.
        assets(i).name = nm;
        assets(i).mult = max(1, round(m));
        assets(i).acresPerUse = max(0, S);
        assets(i).cycleDays = max(1e-6, T);

        % Start each asset after half of one cycle. This avoids every asset
        % applying suppression at exactly time zero.
        assets(i).startDelayDays = 0.5 * assets(i).cycleDays;
    end
end

function [pulseByType, names, cumSuppTotal] = build_pulse_trains(tPostDays, assets, dtDays)
    % Build discrete suppression pulse trains for each asset type.
    %
    % Each asset contributes a pulse of suppression capacity every time it
    % completes one operational cycle. Multiplicity spreads those events out
    % so multiple copies of the same asset type do not all act at the same
    % instant.

    % Number of asset types and number of time steps.
    K  = numel(assets);
    nT = numel(tPostDays);

    % pulseByType stores suppression pulses by time and asset type.
    pulseByType = zeros(nT, K);

    % names stores the asset names corresponding to each pulse column.
    names = strings(K,1);

    % cumSuppTotal stores cumulative suppression summed across all asset
    % types.
    cumSuppTotal = zeros(nT,1);

    % Build one pulse train per asset type.
    for k = 1:K
        a = assets(k);
        names(k) = string(a.name);

        % Read and sanitize asset properties.
        m  = max(1, round(a.mult));
        S  = max(0, a.acresPerUse);
        Td = max(1e-6, a.cycleDays);
        t0 = max(0, a.startDelayDays);

        % Divide the cycle time by multiplicity. For example, four similar
        % assets with a 4-hour cycle are approximated as one pulse every hour.
        deltaDays = Td / m;

        % Do not allow events to occur more frequently than the simulation
        % time step.
        if deltaDays < dtDays
            deltaDays = dtDays;
        end

        % Generate event times from the asset start delay to the end of the
        % simulation window.
        tEnd = tPostDays(end);
        eventTimes = t0 : deltaDays : tEnd;

        % Convert event times to indices in the time vector.
        idx = round(eventTimes ./ dtDays) + 1;

        % Keep only valid indices inside the simulation array.
        idx = idx(idx >= 1 & idx <= nT);

        % Create a pulse vector for this asset type.
        p = zeros(nT,1);
        p(idx) = S;

        % Store this asset's pulse train and add its cumulative contribution
        % to the total suppression curve.
        pulseByType(:,k) = p;
        cumSuppTotal = cumSuppTotal + cumsum(p);
    end
end

function T = default_cycle_days(name)
    % Return a default suppression cycle time for a given asset name.
    % The output T is in days.

    % Convert asset name to lowercase so matching is case-insensitive.
    s = lower(string(name));

    % Assign default cycle times by asset type. Values are converted from
    % hours to days using division by 24.
    if contains(s,"very large air tanker") || contains(s,"vlat")
        T = 4/24;
    elseif contains(s,"large air tanker") || contains(s,"lat")
        T = 3/24;
    elseif contains(s,"single engine airtanker") || contains(s,"seat")
        T = 2/24;
    elseif contains(s,"helicopters type i")
        T = 1.5/24;
    elseif contains(s,"helicopters type ii")
        T = 1.25/24;
    elseif contains(s,"helicopters type iii")
        T = 1.0/24;
    elseif contains(s,"fire engines")
        T = 0.5/24;
    else
        % Generic fallback cycle time for assets not explicitly listed.
        T = 2/24;
    end
end

function val = getFieldAny(S, names, defaultVal)
    % Return the first available field from a structure.
    %
    % This helper lets the model accept several possible field names for the
    % same type of input. It makes the script more tolerant of slightly
    % different resource-structure formats.

    % Start with the default value.
    val = defaultVal;

    % Loop through all possible field names.
    for i = 1:numel(names)
        fn = names{i};

        % If the input is a structure and contains this field, return it.
        if isstruct(S) && isfield(S, fn)
            val = S.(fn);
            return;
        end
    end
end

%% ===== GIF helper =====

function gifWriteFrame = make_gif_frame_writer(gifFile, delayTime)
    % Create a nested helper function that writes animation frames to a GIF.
    %
    % The returned function handle, gifWriteFrame, can be passed into other
    % simulation functions. Those functions can call gifWriteFrame each time
    % they want to append a new animation frame.

    % Normalize inputs.
    gifFile = char(string(gifFile));
    delayTime = double(delayTime);

    % Return a handle to the nested frame-writing function.
    gifWriteFrame = @writeFrame;

    function writeFrame(figHandle, frameIdx)
        % Write the current contents of a figure to the GIF file.

        % If no frame index is provided, assume this is the first frame.
        if nargin < 2 || isempty(frameIdx), frameIdx = 1; end

        % If the figure handle is invalid, do nothing.
        if isempty(figHandle) || ~ishandle(figHandle), return; end

        % Make sure the figure is fully rendered before capturing it.
        drawnow;

        % Capture the figure as an image.
        fr = getframe(figHandle);
        img = frame2im(fr);

        % Convert the RGB image to an indexed image required by GIF format.
        [imind, cm] = rgb2ind(img, 256);

        % Create the GIF on the first frame, then append later frames.
        if frameIdx == 1
            imwrite(imind, cm, gifFile, 'gif', 'Loopcount', inf, 'DelayTime', delayTime);
        else
            imwrite(imind, cm, gifFile, 'gif', 'WriteMode', 'append', 'DelayTime', delayTime);
        end
    end
end

function [tDays, aAcres] = synthesize_nominal_growth_curve(A0_acres, dayPerimeter, dtDays, shapeK)
%SYNTHESIZE_NOMINAL_GROWTH_CURVE
% Builds a smooth nominal growth curve from ignition to the perimeter day.
%
% This function is used only in fast mode when no explicit nominal growth
% history has been supplied. It creates a smooth curve that starts near zero,
% increases monotonically, and reaches A0_acres exactly at dayPerimeter.
%
% The curve shape is:
%   a(t) = A0 * (1 - exp(-k*s)) / (1 - exp(-k))
%   s    = t / dayPerimeter
%
% Larger shapeK values make the curve rise more sharply earlier in the
% simulation.

    % If the target burned area is invalid, return a zero-area curve.
    if ~isfinite(A0_acres) || A0_acres <= 0
        tDays = 0;
        aAcres = 0;
        return;
    end

    % Use a safe perimeter day if the supplied value is invalid.
    if ~isfinite(dayPerimeter) || dayPerimeter <= 0
        dayPerimeter = 1;
    end

    % Use a default 0.25-hour time step if the supplied time step is invalid.
    if ~isfinite(dtDays) || dtDays <= 0
        dtDays = 0.25 / 24;
    end

    % Use a default shape value if the supplied shape factor is invalid.
    if ~isfinite(shapeK) || shapeK <= 0
        shapeK = 5.0;
    end

    % Build a time vector from ignition to the perimeter day.
    tDays = (0:dtDays:dayPerimeter).';

    % Ensure the final point lands exactly on the perimeter day.
    if isempty(tDays) || abs(tDays(end) - dayPerimeter) > 1e-12
        tDays = [tDays; dayPerimeter];
    end

    % Normalize time so the curve runs from s = 0 to s = 1.
    s = tDays / dayPerimeter;

    % Generate the synthetic growth curve.
    aAcres = A0_acres * (1 - exp(-shapeK * s)) / (1 - exp(-shapeK));

    % Protect against numerical negatives and force the final value to equal
    % the requested target area exactly.
    aAcres = max(aAcres, 0);
    aAcres(end) = A0_acres;
end

%% ========================= NEW HELPERS =========================

function [mask_snap, modeStr] = extract_butte_red_mask(I_snap)
    % Extract a red fire-perimeter trace from the screenshot.
    %
    % This is used for the Butte County case, where the fire perimeter is
    % represented by a red outline or red-filled region.

    % Convert the RGB screenshot to HSV color space. HSV makes it easier to
    % isolate red pixels using hue, saturation, and value thresholds.
    Ihsv = rgb2hsv(I_snap);
    Hh = Ihsv(:,:,1); 
    S = Ihsv(:,:,2); 
    V = Ihsv(:,:,3);

    % Build an initial red mask. Red appears near both 0 and 1 in HSV hue,
    % so both ends of the hue range are included.
    mask_snap = (S > 0.25) & (V > 0.20) & ((Hh < 0.05) | (Hh > 0.95));

    % Remove small noisy regions.
    mask_snap = bwareaopen(mask_snap, 200);

    % Close small gaps in the perimeter region.
    mask_snap = imclose(mask_snap, strel('disk', 3));

    % Fill holes so the perimeter becomes a solid region.
    mask_snap = imfill(mask_snap, 'holes');

    % If multiple red regions remain, keep only the largest connected region.
    CC = bwconncomp(mask_snap);
    if CC.NumObjects >= 1
        np = cellfun(@numel, CC.PixelIdxList);
        [~,imx] = max(np);
        tmp = false(size(mask_snap));
        tmp(CC.PixelIdxList{imx}) = true;
        mask_snap = tmp;
    end

    % Return a label describing the extraction method.
    modeStr = "red-perimeter";
end

function [mask_snap, modeStr] = extract_darkscar_mask(I_snap)
    % Extract a dark burn-scar region from the screenshot.
    %
    % This is used for scenarios where the fire area is represented as a
    % darkened scar rather than a red perimeter line.

    % Convert image to double precision for consistent color calculations.
    I = im2double(I_snap);

    % Convert to HSV to separate hue, saturation, and brightness.
    Ihsv = rgb2hsv(I);
    H = Ihsv(:,:,1);
    S = Ihsv(:,:,2);
    V = Ihsv(:,:,3);

    % Convert to LAB color space. The L channel measures lightness and helps
    % identify dark burn-scar pixels.
    Ilab = rgb2lab(I);
    L = Ilab(:,:,1); %#ok<NASGU>

    % Identify dark pixels using brightness and LAB lightness thresholds.
    dark1 = V < 0.52;
    dark2 = Ilab(:,:,1) < 55;

    % Exclude common non-fire regions that can also appear dark or low
    % saturation, such as map panels, sky, and gray text.
    notWhitePan = ~(V > 0.78 & S < 0.16);
    notBlueSky  = ~(H > 0.50 & H < 0.72 & V > 0.45);
    notGrayText = ~(S < 0.06 & V < 0.35);

    % Build the initial burn-scar mask.
    mask_snap = (dark1 | dark2) & notWhitePan & notBlueSky & notGrayText;

    % Apply median filtering and morphological cleanup to remove speckle,
    % connect nearby regions, fill holes, and remove small objects.
    mask_snap = medfilt2(mask_snap,[3 3]);
    mask_snap = imopen(mask_snap, strel('disk', 2));
    mask_snap = imclose(mask_snap, strel('disk', 5));
    mask_snap = imfill(mask_snap, 'holes');
    mask_snap = bwareaopen(mask_snap, 500);

    % Inspect connected components so only plausible burn-scar regions are
    % kept.
    CC = bwconncomp(mask_snap);
    if CC.NumObjects >= 1
        stats = regionprops(CC, 'Area', 'Centroid');
        keepMask = false(size(mask_snap));
        Hmask = size(mask_snap,1);

        % Keep components that are large enough and located away from the
        % upper image region, where headers or map artifacts often appear.
        for k = 1:numel(stats)
            areaK = stats(k).Area;
            cy    = stats(k).Centroid(2);
            if areaK > 2000 && cy > 0.28*Hmask
                keepMask(CC.PixelIdxList{k}) = true;
            end
        end

        % If at least one plausible region was found, use the filtered mask
        % and clean it one more time.
        if any(keepMask(:))
            mask_snap = keepMask;
            mask_snap = imclose(mask_snap, strel('disk', 7));
            mask_snap = imfill(mask_snap, 'holes');
        end
    end

    % Return a label describing the extraction method.
    modeStr = "dark-burn-scar";
end

function [slopeEarly, slopeTail] = estimate_delay_slopes(outFire, cfg)
    % Estimate two fire-growth slopes from the nominal growth curve.
    %
    % slopeEarly captures rapid early growth shortly after ignition.
    % slopeTail captures growth near the perimeter day. These are blended
    % elsewhere to approximate additional fire growth during detection or
    % coordination delays.

    % Initialize both outputs as NaN. They stay NaN if the growth curve is
    % missing or not usable.
    slopeEarly = NaN;
    slopeTail  = NaN;

    % Require a valid fire-growth output with time and area fields.
    if isempty(outFire) || ~isfield(outFire,'tHours') || ~isfield(outFire,'areaAcres')
        return;
    end

    % Convert time from hours to days and force area into a column vector.
    tDays = outFire.tHours(:) / 24;
    a     = outFire.areaAcres(:);

    % Remove duplicate time entries.
    [tDays, iu] = unique(tDays, 'stable');
    a = a(iu);

    % Keep only valid finite values.
    keep = isfinite(tDays) & isfinite(a);
    tDays = tDays(keep);
    a     = a(keep);

    % Need at least two points to compute a slope.
    if numel(tDays) < 2
        return;
    end

    % Estimate early growth using the first few positive burn-area points.
    idxPos = find(a > 0);
    if numel(idxPos) >= 2
        i1 = idxPos(1);
        i2 = min(numel(tDays), i1 + 3);

        if tDays(i2) > tDays(i1)
            slopeEarly = (a(i2) - a(i1)) / (tDays(i2) - tDays(i1));
        end
    end

    % Estimate tail growth using points within one day of the perimeter day.
    tPerim = cfg.dayPerimeter;
    idxTail = find(tDays >= (tPerim - 1.0) & tDays <= tPerim);

    % If there are not enough points near the perimeter day, use the final
    % few points in the curve as a fallback.
    if numel(idxTail) < 2
        idxTail = max(1, numel(tDays)-3):numel(tDays);
    end

    % Compute the tail slope in acres per day.
    if numel(idxTail) >= 2 && tDays(idxTail(end)) > tDays(idxTail(1))
        slopeTail = (a(idxTail(end)) - a(idxTail(1))) / ...
                    (tDays(idxTail(end)) - tDays(idxTail(1)));
    end
end
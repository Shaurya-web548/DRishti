function [vesselMaskDL, dlOK, dlInfo] = dlSegmentVessels(Iw, fov, modelPath)
%DLSEGMENTVESSELS  Try to segment vessels using a trained U-Net. Never errors out.
%
%   [vesselMaskDL, dlOK, dlInfo] = dlSegmentVessels(Iw, fov, modelPath)
%
%   Iw          working-resolution RGB image (same one segmentRetina already builds)
%   fov         logical field-of-view mask, same size as Iw
%   modelPath   path to a saved semantic segmentation network, e.g. 'vesselUNet.mat'
%               (must contain a variable called 'net' — a trained dlnetwork /
%               SeriesNetwork for semantic segmentation, 2 classes: 'vessel','background')
%
%   vesselMaskDL   logical mask, same size as Iw. All-false if DL was not used.
%   dlOK            true only if the model loaded AND ran successfully
%   dlInfo           struct: .reason (why DL was/was not used), .modelPath
%
%   THIS FUNCTION NEVER THROWS. If anything goes wrong - missing file, missing
%   toolbox, bad model, inference error - it returns dlOK = false and an empty
%   mask, so the caller can safely fall back to the classical result.

vesselMaskDL = false(size(fov));
dlOK = false;
dlInfo.modelPath = modelPath;

% ---- Guard 1: does the model file even exist?
if isempty(modelPath) || ~isfile(modelPath)
    dlInfo.reason = 'no DL model file found - using classical only';
    return;
end

% ---- Guard 2: is the Deep Learning Toolbox available?
if exist('semanticseg', 'file') ~= 2
    dlInfo.reason = 'Deep Learning Toolbox not available - using classical only';
    return;
end

% ---- Guard 3: try to load and run. Any failure here is caught, not thrown.
try
    S = load(modelPath);
    if ~isfield(S, 'net')
        dlInfo.reason = 'model file does not contain a variable named "net" - using classical only';
        return;
    end
    net = S.net;

    % Run semantic segmentation. Output C is a categorical label image.
    C = semanticseg(Iw, net);
    vesselMaskDL = (C == 'vessel') & fov;

    dlOK = true;
    dlInfo.reason = 'DL vessel segmentation ran successfully';
catch ME
    vesselMaskDL = false(size(fov));
    dlOK = false;
    dlInfo.reason = ['DL inference failed (' ME.message ') - using classical only'];
end
end

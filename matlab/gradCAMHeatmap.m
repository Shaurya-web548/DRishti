function [heatmapImage, scoreMap, layers] = gradCAMHeatmap(cnnModel, image, classIdx, opts)
%GRADCAMHEATMAP  Grad-CAM heatmap for one class decision, blended onto the image.
%
%   [heatmapImage, scoreMap, layers] = gradCAMHeatmap(cnnModel, image, classIdx)
%
%   cnnModel   dlnetwork / DAGNetwork / SeriesNetwork, or the struct from trainDRClassifier
%   image      file path or RGB array
%   classIdx   1-based index of the class to explain (for grades 0-4 that is grade + 1);
%              [] = the class the network predicts
%   Options:   Alpha (0.45) heatmap opacity, Colormap ('jet'), and FeatureLayer /
%              ReductionLayer if MATLAB's automatic layer choice needs overriding.
%
%   heatmapImage  uint8 RGB, same size as the input image (black background kept black)
%   scoreMap      Grad-CAM map scaled to 0-1, same size as the input image
%   layers        the feature / reduction layers gradCAM used
%
%   Uses gradCAM from Deep Learning Toolbox (R2021a or newer).

arguments
    cnnModel
    image
    classIdx = []
    opts.Alpha (1,1) double = 0.45
    opts.Colormap = 'jet'
    opts.FeatureLayer = ''
    opts.ReductionLayer = ''
end
if isstruct(cnnModel), net = cnnModel.net; else, net = cnnModel; end
if isstruct(cnnModel) && isfield(cnnModel, 'inputSize'), inputSize = cnnModel.inputSize;
else, inputSize = net.Layers(1).InputSize; end

img = loadImage(image);
[H, W, ~] = size(img);
X = single(imresize(img, inputSize(1:2)));                        % network-sized copy, 0-255

if isempty(classIdx)                                              % explain the network's own choice
    probs = predict(net, X);
    if isa(probs, 'dlarray'), probs = extractdata(probs); end
    [~, classIdx] = max(gather(double(probs(:))));
end

nv = {};
if ~isempty(opts.FeatureLayer),   nv = [nv, {'FeatureLayer',   opts.FeatureLayer}];   end
if ~isempty(opts.ReductionLayer), nv = [nv, {'ReductionLayer', opts.ReductionLayer}]; end
[scoreMap, featLayer, redLayer] = gradCAM(net, X, classIdx, nv{:});   % MATLAB's built-in Grad-CAM
layers = struct('feature', featLayer, 'reduction', redLayer);

scoreMap = imresize(double(gather(scoreMap)), [H W]);             % back to the original size
scoreMap = scoreMap - min(scoreMap(:));
if max(scoreMap(:)) > 0, scoreMap = scoreMap / max(scoreMap(:)); end

if ischar(opts.Colormap) || isstring(opts.Colormap), cmap = feval(char(opts.Colormap), 256);
else, cmap = opts.Colormap; end
heatRGB = ind2rgb(1 + round((size(cmap, 1) - 1) * scoreMap), cmap);
alpha   = opts.Alpha * double(rgb2gray(img) > 15);                % no heat on the black background
heatmapImage = uint8((1 - alpha) .* double(img) + alpha .* (255 * heatRGB));
end

%% ============================================================ LOCAL FUNCTIONS
function img = loadImage(image)
if ischar(image) || isstring(image), img = imread(char(image)); else, img = image; end
if size(img, 3) > 3, img = img(:, :, 1:3); end
img = im2uint8(img);
if size(img, 3) == 1, img = repmat(img, [1 1 3]); end
end

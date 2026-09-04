function model = trainDRClassifier(dataDir, opts)
% Train APTOS 2019 diabetic retinopathy classifier
% Designed for a GPU with about 6 GB VRAM.

arguments
    dataDir (1,1) string

    opts.Backbone (1,1) string {mustBeMember( ...
        opts.Backbone, ["efficientnetb0","resnet50"])} = "efficientnetb0"

    opts.MaxEpochs (1,1) double = 10
    opts.MiniBatchSize (1,1) double = 4
    opts.InitialLearnRate (1,1) double = 1e-4
    opts.BalanceClasses (1,1) logical = true

    opts.OutputFile (1,1) string = "drClassifier.mat"

    opts.ExecutionEnvironment (1,1) string {mustBeMember( ...
        opts.ExecutionEnvironment, ["gpu","cpu","auto"])} = "gpu"
end

%% ---------------------------------------------------------
% 1. LOAD DATA
rng(0);

imds = imageDatastore( ...
    dataDir, ...
    'IncludeSubfolders', true, ...
    'LabelSource', 'foldernames');

classNames = string(categories(imds.Labels))';
grades = str2double(classNames);

disp("Dataset:");
disp(countEachLabel(imds));

%% ---------------------------------------------------------
% 1b. SUBSAMPLE DATASET (insert right after imds is created, before splitEachLabel)
maxPerClass = 200;   % <-- tune this to what your RAM can handle

tbl = countEachLabel(imds);
subIdxCells = cell(height(tbl),1);

for k = 1:height(tbl)
    idx = find(imds.Labels == tbl.Label(k));
    n = min(numel(idx), maxPerClass);
    idx = idx(randperm(numel(idx), n));   % random subset, no repeats
    subIdxCells{k} = idx;
end

subIdx = vertcat(subIdxCells{:});

imds = imageDatastore( ...
    imds.Files(subIdx), ...
    'Labels', imds.Labels(subIdx));

disp("Subsampled dataset:");
disp(countEachLabel(imds));

%% ---------------------------------------------------------
% 2. SPLIT DATA
[imdsTrain, imdsVal, imdsTest] = splitEachLabel( ...
    imds, ...
    0.70, ...
    0.15, ...
    'randomized');

disp("Training:");
disp(countEachLabel(imdsTrain));

disp("Validation:");
disp(countEachLabel(imdsVal));

disp("Test:");
disp(countEachLabel(imdsTest));

%% ---------------------------------------------------------
% 3. BALANCE CLASSES
if opts.BalanceClasses

    tbl = countEachLabel(imdsTrain);
    maxCount = max(tbl.Count);

    keepCells = cell(height(tbl),1);

    for k = 1:height(tbl)

        idx = find(imdsTrain.Labels == tbl.Label(k));

        keepCells{k} = idx( ...
            randi(numel(idx), maxCount, 1));

    end

    keepIdx = vertcat(keepCells{:});

    imdsTrain = imageDatastore( ...
        imdsTrain.Files(keepIdx), ...
        'Labels', imdsTrain.Labels(keepIdx));

end

%% ---------------------------------------------------------
% 4. LOAD PRETRAINED NETWORK
net = imagePretrainedNetwork( ...
    opts.Backbone, ...
    'NumClasses', numel(classNames));

inputSize = net.Layers(1).InputSize;

fprintf("\nNetwork: %s\n", opts.Backbone);
fprintf("Input size: %d x %d x %d\n", ...
    inputSize(1), inputSize(2), inputSize(3));

%% ---------------------------------------------------------
% 5. LEARNING RATE FACTOR FOR FINAL LAYER
fcIdx = find( ...
    arrayfun(@(l) ...
    isa(l,'nnet.cnn.layer.FullyConnectedLayer'), ...
    net.Layers), ...
    1, ...
    'last');

if ~isempty(fcIdx)

    net = setLearnRateFactor( ...
        net, ...
        net.Layers(fcIdx).Name, ...
        'Weights', 10);

    net = setLearnRateFactor( ...
        net, ...
        net.Layers(fcIdx).Name, ...
        'Bias', 10);

end

%% ---------------------------------------------------------
% 6. DATA AUGMENTATION
aug = imageDataAugmenter( ...
    'RandRotation', [-15 15], ...
    'RandXReflection', true, ...
    'RandScale', [0.9 1.1]);

augTrain = augmentedImageDatastore( ...
    inputSize(1:2), ...
    imdsTrain, ...
    'DataAugmentation', aug, ...
    'ColorPreprocessing', 'gray2rgb');

augVal = augmentedImageDatastore( ...
    inputSize(1:2), ...
    imdsVal, ...
    'ColorPreprocessing', 'gray2rgb');

augTest = augmentedImageDatastore( ...
    inputSize(1:2), ...
    imdsTest, ...
    'ColorPreprocessing', 'gray2rgb');

%% ---------------------------------------------------------
% 7. TRAINING OPTIONS

itersPerEpoch = max( ...
    1, ...
    floor(numel(imdsTrain.Files) / opts.MiniBatchSize));

options = trainingOptions('adam', ...
    'InitialLearnRate', opts.InitialLearnRate, ...
    'MaxEpochs', opts.MaxEpochs, ...
    'MiniBatchSize', opts.MiniBatchSize, ...
    'Shuffle', 'every-epoch', ...
    'ValidationData', augVal, ...
    'ValidationFrequency', itersPerEpoch, ...
    'ValidationPatience', 4, ...
    'OutputNetwork', 'best-validation', ...
    'Metrics', 'accuracy', ...
    'Plots', 'training-progress', ...
    'ExecutionEnvironment', opts.ExecutionEnvironment, ...
    'Verbose', true);

%% ---------------------------------------------------------
% 8. TRAIN
fprintf("\n====================================\n");
fprintf("STARTING TRAINING\n");
fprintf("====================================\n");

net = trainnet( ...
    augTrain, ...
    net, ...
    'crossentropy', ...
    options);

%% ---------------------------------------------------------
% 9. VALIDATION
valScores = gather(minibatchpredict( ...
    net, ...
    augVal, ...
    'MiniBatchSize', opts.MiniBatchSize));

%% ---------------------------------------------------------
% 10. TEST
testScores = gather(minibatchpredict( ...
    net, ...
    augTest, ...
    'MiniBatchSize', opts.MiniBatchSize));

%% ---------------------------------------------------------
% 11. GET TRUE LABELS
valGrades = str2double(string(imdsVal.Labels));
testGrades = str2double(string(imdsTest.Labels));

%% ---------------------------------------------------------
% 12. PREDICTIONS
[~, predIdx] = max(testScores, [], 2);
[~, truthIdx] = ismember(testGrades, grades);

testPred = grades(predIdx);

%% ---------------------------------------------------------
% 13. ACCURACY
acc = mean(testPred == testGrades);

%% ---------------------------------------------------------
% 14. QUADRATIC KAPPA
kappa = quadraticKappa( ...
    truthIdx, ...
    predIdx, ...
    numel(grades));

fprintf("\n====================================\n");
fprintf("RESULTS\n");
fprintf("Accuracy: %.2f%%\n", acc * 100);
fprintf("Quadratic Kappa: %.4f\n", kappa);
fprintf("====================================\n");

%% ---------------------------------------------------------
% 15. CONFUSION MATRIX
figure;

confusionchart( ...
    categorical(testGrades, grades), ...
    categorical(testPred, grades), ...
    'Title', sprintf( ...
    'APTOS 2019 - Accuracy %.1f%% - Kappa %.3f', ...
    acc * 100, ...
    kappa));

%% ---------------------------------------------------------
% 16. SAVE MODEL
model.net = net;
model.backbone = opts.Backbone;
model.classNames = classNames;
model.grades = grades;
model.inputSize = inputSize;

model.imdsVal = imdsVal;
model.imdsTest = imdsTest;

model.valScores = valScores;
model.valGrades = valGrades;

model.testScores = testScores;
model.testGrades = testGrades;

model.testAccuracy = acc;
model.testKappa = kappa;

save( ...
    char(opts.OutputFile), ...
    '-struct', ...
    'model');

fprintf("\nModel saved as: %s\n", opts.OutputFile);

end


%% =========================================================
% QUADRATIC WEIGHTED KAPPA
function k = quadraticKappa(t,p,n)

O = accumarray( ...
    [t(:) p(:)], ...
    1, ...
    [n n]);

E = sum(O,2) * sum(O,1) / sum(O(:));

[i,j] = ndgrid(1:n);

Wt = (i-j).^2 / (n-1)^2;

k = 1 - ...
    sum(Wt(:).*O(:)) / ...
    sum(Wt(:).*E(:));

end
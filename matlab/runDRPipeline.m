%% runDRPipeline - end-to-end test of parts (1), (2) and (3)
% Prerequisite: data/0 ... data/4 folders. Build them once per dataset, e.g.
%   sortIntoGradeFolders('train.csv', 'train_images', 'data', 'id_code', 'diagnosis')
% (see sortIntoGradeFolders for the IDRiD and Messidor-2 column names).
dataDir = 'data';

%% (1) Fine-tune the CNN
% First run: add MaxImagesPerClass=100, MaxEpochs=2 to check everything works in minutes.
model = trainDRClassifier(dataDir, Backbone="resnet50", MaxEpochs=8);
% Later sessions:  model = load('drClassifier.mat');

%% (3a) Tune the referable-DR cut-off on the validation split, then check it on the test split
pRefVal  = sum(model.valScores(:, model.grades >= 2), 2);
opPoint  = tuneReferableThreshold(pRefVal, model.valGrades >= 2, 0.90, 0.85);

pRefTest = sum(model.testScores(:, model.grades >= 2), 2);
fprintf('Test split at cut-off %.3f: sensitivity %.1f%%, specificity %.1f%%\n', opPoint.threshold, ...
    100 * mean(pRefTest(model.testGrades >= 2) >= opPoint.threshold), ...
    100 * mean(pRefTest(model.testGrades <  2) <  opPoint.threshold));

%% (2) + (3b) Combined decision for one image
imgFile = model.imdsTest.Files{1};
seg = segmentRetina(imgFile);                                     % lesions from the earlier function
[ruleGrade, ruleInfo] = gradeByRules(seg, seg.opticDisc.center);  % ICDR scale + 4-2-1 rule
[cnnGrade, probs]     = predictDRGrade(model, imgFile);
decision = combineGrades(probs, ruleGrade, opPoint.threshold, model.grades)

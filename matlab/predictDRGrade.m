function [grade, probs] = predictDRGrade(model, input)
% Predict diabetic retinopathy grade.
%
% input can be:
%   - image file path
%   - RGB image
%   - imageDatastore

%% ---------------------------------------------------------
% IMAGE DATASTORE
if isa(input, 'matlab.io.datastore.ImageDatastore')

    aug = augmentedImageDatastore( ...
        model.inputSize(1:2), ...
        input, ...
        'ColorPreprocessing', 'gray2rgb');

    probs = minibatchpredict( ...
        model.net, ...
        aug, ...
        'MiniBatchSize', 4);

%% ---------------------------------------------------------
% SINGLE IMAGE
else

    if ischar(input) || isstring(input)
        input = imread(char(input));
    end

    % Convert grayscale to RGB
    if size(input,3) == 1
        input = repmat(input,[1 1 3]);
    end

    % Resize
    X = single(imresize( ...
        im2uint8(input), ...
        model.inputSize(1:2)));

    % Predict
    probs = predict(model.net,X);

    % Convert dlarray
    if isa(probs,'dlarray')
        probs = extractdata(probs);
    end

    probs = reshape(probs,1,[]);

end

%% ---------------------------------------------------------
% CLEAN OUTPUT
probs = gather(probs);

[~,idx] = max(probs,[],2);

grade = reshape( ...
    model.grades(idx), ...
    [],1);

end
classdef Layer < matlab.mixin.Copyable
%Layer
%   The Layer object is the main building block for defining networks in
%   the autonn framework. It specifies a function call in a computational
%   graph.
%
%   Generally there is no need to invoke Layer directly. One can start
%   by defining the network inputs: (Input is a subclass of Layer)
%
%      images = Input() ;
%      labels = Input() ;
%
%   And then composing them using the overloaded functions:
%
%      prediction = vl_nnconv(images, 'size', [1, 1, 4, 3]) ;
%      loss = vl_nnsoftmaxloss(prediction, labels) ;
%
%   Both vl_nnconv and vl_nnsoftmaxloss will not run directly, but are
%   overloaded to return Layer objects that contain the function call
%   information.
%
%   See also NET.

% Copyright (C) 2016 Joao F. Henriques.
% All rights reserved.
%
% This file is part of the VLFeat library and is made available under
% the terms of the BSD license (see the COPYING file).

  properties (Access = public)
    inputs = {}  % list of inputs, either constants or other Layers
    testInputs = 'same'  % list of inputs used in test mode, may be different
  end
  
  properties (SetAccess = public, GetAccess = public)
    func = []  % main function being called
    testFunc = []  % function called in test mode (empty to use the same as in normal mode; 'none' to disable, e.g. dropout)
    name = ''  % optional name (for debugging mostly; a layer is a unique handle object that can be passed around)
    numInputDer = []  % to manually specify the number of input derivatives returned in bwd mode
    accumDer = true  % to manually specify that the input derivatives are *not* accumulated. used to implement ReLU short-circuiting.
    meta = []  % optional meta properties
    source = []  % call stack (source files and line numbers) where this Layer was created
    diagnostics = []  % whether to plot the mean, min and max of the Layer's output var. empty for automatic (network outputs only).
  end
  
  properties (SetAccess = {?Net}, GetAccess = public)
    outputVar = 0  % index of the output var in a Net, used during its construction
  end
  
  properties (Access = protected)
    copied = []  % reference of deep copied object, used internally for deepCopy()
    enableCycleChecks = true  % to avoid redundant cycle checks when implicitly calling set.inputs()
  end
  
  methods  % methods defined in their own files
    objs = find(obj, varargin)
    sz = evalOutputSize(obj, varargin)
    sequentialNames(varargin)
    display(obj, name)
    print(obj)
  end
  methods (Access = {?Net, ?Layer})
    [visited, selected, numVisited] = findRecursive(obj, what, n, depth, visited, selected, numVisited)
    [other, visited, numVisited] = deepCopyRecursive(obj, shared, rename, visited, numVisited)
  end
  
  methods
    function obj = Layer(func, varargin)  % wrap a function call
      obj.saveStack() ;  % record source file and line number, for debugging
      
      if nargin == 0 && (isa(obj, 'Input') || isa(obj, 'Param'))
        return  % called during Input or Param construction, nothing to do
      end
      
      % convert from SimpleNN to DagNN
      if isstruct(func) && isfield(func, 'layers')
        func = dagnn.DagNN.fromSimpleNN(func, 'CanonicalNames', true) ;
      end
      
      % convert from DagNN to Layer
      if isa(func, 'dagnn.DagNN')
         obj = dagnn2autonn(func) ;
         if isscalar(obj)
           obj = obj{1} ;
         else  % wrap multiple outputs in a weighted sum
           obj = Layer(@vl_nnwsum, obj{:}, 'weights', ones(1, numel(obj))) ;
         end
         return
      else
        assert(isa(func, 'function_handle'), ...
          'Input must be a function handle, a SimpleNN struct or a DagNN.') ;
      end
      
      assert(isa(func, 'function_handle'), 'Must specify a function handle as the first argument.') ;
      
      obj.enableCycleChecks = false ;
      obj.func = func ;
      obj.inputs = varargin(:)' ;
      
      % call setup function if defined. it can change the inputs list (not
      % allowed for outside functions, to preserve call graph structure).
      [obj.inputs, obj.testInputs] = autonn_setup(obj) ;
      obj.enableCycleChecks = true ;
    end
    
    function set.inputs(obj, newInputs)
      if obj.enableCycleChecks
        % must check for cycles, to ensure DAG structure.
        % to do: should also do the same for testInputs; that property will
        % be removed in the new test-mode implementation though.
        visited = {} ;
        numVisited = 0 ;
        for i = 1:numel(newInputs)
          if isa(newInputs{i}, 'Layer')
            [visited, numVisited] = newInputs{i}.cycleCheckRecursive(obj, visited, numVisited) ;
          end
        end
      end
      
      obj.inputs = newInputs;
    end
    
    function other = deepCopy(obj, varargin)
      % OTHER = OBJ.DEEPCOPY(SHAREDLAYER1, SHAREDLAYER2, ...)
      % OTHER = OBJ.DEEPCOPY({SHAREDLAYER1, SHAREDLAYER2, ...})
      % Returns a deep copy of a layer, excluding SHAREDLAYER1,
      % SHAREDLAYER2, etc, which are optional. This can be used to
      % implement shared Params, or define the boundaries of the deep copy.
      %
      % OTHER = OBJ.DEEPCOPY(..., RENAME)
      % Specifies a function handle to be evaluated on each name, possibly
      % modifying it (e.g. append a prefix or suffix).
      %
      % OTHER = OBJ.DEEPCOPY(..., 'noName')
      % Does not copy object names (they are left empty).
      %
      % To create a shallow copy, use OTHER = OBJ.COPY().
      
      rename = @deal ;  % no renaming by default
      if ~isempty(varargin)
        if isa(varargin{end}, 'function_handle')
          rename = varargin{end} ;  % specified rename function
          varargin(end) = [] ;
        elseif ischar(varargin{end})
          assert(strcmp(varargin{end}, 'noName'), 'Invalid option.') ;
          rename = @(~) [] ;  % assign empty to name
          varargin(end) = [] ;
        end
      end
      
      if isscalar(varargin) && iscell(varargin{1})  % passed in cell array
        varargin = varargin{1} ;
      end
      obj.deepCopyReset({}, 0) ;
      other = obj.deepCopyRecursive(varargin, rename, {}, 0) ;
    end
    
    
    % overloaded MatConvNet functions
    function y = vl_nnconv(obj, varargin)
      y = Layer(@vl_nnconv, obj, varargin{:}) ;
    end
    function y = vl_nnconvt(obj, varargin)
      y = Layer(@vl_nnconvt, obj, varargin{:}) ;
    end
    function y = vl_nnpool(obj, varargin)
      y = Layer(@vl_nnpool, obj, varargin{:}) ;
    end
    function y = vl_nnrelu(obj, varargin)
      y = Layer(@vl_nnrelu, obj, varargin{:}) ;
    end
    function y = vl_nnsigmoid(obj, varargin)
      y = Layer(@vl_nnsigmoid, obj, varargin{:}) ;
    end
    function y = vl_nndropout(obj, varargin)
      y = Layer(@vl_nndropout, obj, varargin{:}) ;
    end
    function y = vl_nnbilinearsampler(obj, varargin)
      y = Layer(@vl_nnbilinearsampler, obj, varargin{:}) ;
    end
    function y = vl_nnaffinegrid(obj, varargin)
      y = Layer(@vl_nnaffinegrid, obj, varargin{:}) ;
    end
    function y = vl_nncrop(obj, varargin)
      y = Layer(@vl_nncrop, obj, varargin{:}) ;
    end
    function y = vl_nnnoffset(obj, varargin)
      y = Layer(@vl_nnnoffset, obj, varargin{:}) ;
    end
    function y = vl_nnnormalize(obj, varargin)
      y = Layer(@vl_nnnormalize, obj, varargin{:}) ;
    end
    function y = vl_nnnormalizelp(obj, varargin)
      y = Layer(@vl_nnnormalizelp, obj, varargin{:}) ;
    end
    function y = vl_nnspnorm(obj, varargin)
      y = Layer(@vl_nnspnorm, obj, varargin{:}) ;
    end
    function y = vl_nnbnorm(obj, varargin)
      y = Layer(@vl_nnbnorm, obj, varargin{:}) ;
    end
    function y = vl_nnsoftmax(obj, varargin)
      y = Layer(@vl_nnsoftmax, obj, varargin{:}) ;
    end
    function y = vl_nnpdist(obj, varargin)
      y = Layer(@vl_nnpdist, obj, varargin{:}) ;
    end
    function y = vl_nnsoftmaxloss(obj, varargin)
      y = Layer(@vl_nnsoftmaxloss, obj, varargin{:}) ;
    end
    function y = vl_nnloss(obj, varargin)
      y = Layer(@vl_nnloss, obj, varargin{:}) ;
    end
    
    
    % overloaded native Matlab functions
    function y = reshape(obj, varargin)
      y = Layer(@reshape, obj, varargin{:}) ;
    end
    function y = repmat(obj, varargin)
      y = Layer(@repmat, obj, varargin{:}) ;
    end
    function y = permute(obj, varargin)
      y = Layer(@permute, obj, varargin{:}) ;
    end
    function y = ipermute(obj, varargin)
      y = Layer(@ipermute, obj, varargin{:}) ;
    end
    function y = squeeze(obj, varargin)
      y = Layer(@squeeze, obj, varargin{:}) ;
    end
    function y = size(obj, varargin)
      y = Layer(@size, obj, varargin{:}) ;
    end
    function y = sum(obj, varargin)
      y = Layer(@sum, obj, varargin{:}) ;
    end
    function y = mean(obj, varargin)
      y = Layer(@mean, obj, varargin{:}) ;
    end
    function y = max(obj, varargin)
      y = Layer(@max, obj, varargin{:}) ;
    end
    function y = min(obj, varargin)
      y = Layer(@min, obj, varargin{:}) ;
    end
    function y = abs(obj, varargin)
      y = Layer(@abs, obj, varargin{:}) ;
    end
    function y = sqrt(obj, varargin)
      y = Layer(@sqrt, obj, varargin{:}) ;
    end
    function y = exp(obj, varargin)
      y = Layer(@exp, obj, varargin{:}) ;
    end
    function y = log(obj, varargin)
      y = Layer(@log, obj, varargin{:}) ;
    end
    function y = cat(obj, varargin)
      y = Layer(@cat, obj, varargin{:}) ;
    end
    
    % overloaded math operators. any additions, negative signs and scalar
    % factors are merged into a single vl_nnwsum by the Layer constructor.
    % vl_nnbinaryop does singleton expansion, vl_nnmatrixop does not.
    
    function c = plus(a, b)
      c = Layer(@vl_nnwsum, a, b, 'weights', [1, 1]) ;
    end
    function c = minus(a, b)
      c = Layer(@vl_nnwsum, a, b, 'weights', [1, -1]) ;
    end
    function c = uminus(a)
      c = Layer(@vl_nnwsum, a, 'weights', -1) ;
    end
    function c = uplus(a)
      c = a ;
    end
    
    function c = times(a, b)
      % optimization: for simple scalar constants, use a vl_nnwsum layer
      if isnumeric(a) && isscalar(a)
        c = Layer(@vl_nnwsum, b, 'weights', a) ;
      elseif isnumeric(b) && isscalar(b)
        c = Layer(@vl_nnwsum, a, 'weights', b) ;
      else  % general case
        c = Layer(@vl_nnbinaryop, a, b, @times) ;
      end
    end
    function c = rdivide(a, b)
      if isnumeric(b) && isscalar(b)  % optimization for scalar constants
        c = Layer(@vl_nnwsum, a, 'weights', 1 / b) ;
      else
        c = Layer(@vl_nnbinaryop, a, b, @rdivide) ;
      end
    end
    function c = ldivide(a, b)
      if isnumeric(a) && isscalar(a)  % optimization for scalar constants
        c = Layer(@vl_nnwsum, b, 'weights', 1 / a) ;
      else
        c = Layer(@vl_nnbinaryop, a, b, @ldivide) ;
      end
    end
    function c = power(a, b)
      c = Layer(@vl_nnbinaryop, a, b, @power) ;
    end
    
    function y = transpose(a)
      y = Layer(@vl_nnmatrixop, a, [], @transpose) ;
    end
    function y = ctranspose(a)
      y = Layer(@vl_nnmatrixop, a, [], @ctranspose) ;
    end
    
    function c = mtimes(a, b)
      % optimization: for simple scalar constants, use a vl_nnwsum layer
      if isnumeric(a) && isscalar(a)
        c = Layer(@vl_nnwsum, b, 'weights', a) ;
      elseif isnumeric(b) && isscalar(b)
        c = Layer(@vl_nnwsum, a, 'weights', b) ;
      else  % general case
        c = Layer(@vl_nnmatrixop, a, b, @mtimes) ;
      end
    end
    function c = mrdivide(a, b)
      if isnumeric(b) && isscalar(b)  % optimization for scalar constants
        c = Layer(@vl_nnwsum, a, 'weights', 1 / b) ;
      else
        c = Layer(@vl_nnmatrixop, a, b, @mrdivide) ;
      end
    end
    function c = mldivide(a, b)
      if isnumeric(a) && isscalar(a)  % optimization for scalar constants
        c = Layer(@vl_nnwsum, b, 'weights', 1 / a) ;
      else
        c = Layer(@vl_nnmatrixop, a, b, @mldivide) ;
      end
    end
    function c = mpower(a, b)
      c = Layer(@vl_nnmatrixop, a, b, @mpower) ;
    end
    
    function y = vertcat(obj, varargin)
      y = Layer(@cat, 1, obj, varargin{:}) ;
    end
    function y = horzcat(obj, varargin)
      y = Layer(@cat, 2, obj, varargin{:}) ;
    end
    
    function y = colon(obj, varargin)
      y = Layer(@colon, obj, varargin{:}) ;
    end
    
    % overloaded indexing
    function varargout = subsref(a, s)
      if strcmp(s(1).type, '()')
        varargout{1} = Layer(@autonn_slice, a, s.subs{:}) ;
      else
        [varargout{1:nargout}] = builtin('subsref', a, s) ;
      end
    end
    
    % overload END keyword, e.g. X(1:end-1). see DOC OBJECT-END-INDEXING.
    % a difficult choice: returning a constant size requires knowing all
    % input sizes in advance (i.e. to call evalOutputSize). returning a
    % Layer (on-the-fly size calculation) has overhead and also requires
    % overloading the colon (:) operator.
    function idx = end(obj, dim, ndim)
      error('Not supported, use SIZE(X,DIM) or a constant size instead.') ;
    end
  end
  
  methods (Access = {?Net, ?Layer})
    function [visited, numVisited] = deepCopyReset(obj, visited, numVisited)
      obj.copied = [] ;
      
      % recurse on inputs
      idx = obj.getNextRecursion(visited, numVisited) ;
      for i = idx
        [visited, numVisited] = obj.inputs{i}.deepCopyReset(visited, numVisited) ;
      end
      [visited, numVisited] = obj.markRecursed(visited, numVisited) ;
    end
    
    function [visited, numVisited] = cycleCheckRecursive(obj, root, visited, numVisited)
      assert(obj ~= root, 'Input assignment creates a cycle in the network.') ;
      
      % recurse on inputs
      idx = obj.getNextRecursion(visited, numVisited) ;
      for i = idx
        [visited, numVisited] = obj.inputs{i}.cycleCheckRecursive(root, visited, numVisited) ;
      end
      [visited, numVisited] = obj.markRecursed(visited, numVisited) ;
    end
    
    function idx = getNextRecursion(obj, visited, numVisited)
      % Used by findRecursive, cycleCheckRecursive, deepCopyRecursive, etc,
      % to avoid redundant recursions in very large networks.
      % Returns indexes of inputs to recurse on, that have not been visited
      % yet during this operation. The list of layers seen so far is
      % managed efficiently with a preallocated cell array (VISITED).
      
      valid = false(1, numel(obj.inputs)) ;
      for i = 1:numel(obj.inputs)
        in = obj.inputs{i} ;
        if isa(in, 'Layer')
          valid(i) = true ;
          for j = 1:numVisited
            if in == visited{j}  % already visited this object
              valid(i) = false ;
              break ;
            end
          end
        end
      end
      idx = find(valid) ;
    end
    
    function [visited, numVisited] = markRecursed(obj, visited, numVisited)
      % Add self to visited list, and manage its size (used after
      % getNextRecursion; see findRecursive for an example).
      numVisited = numVisited + 1 ;
      if numVisited > numel(visited)  % pre-allocate
        visited{end + 500} = [] ;
      end
      visited{numVisited} = obj ;
    end
    
    function saveStack(obj)
      % record call stack (source files and line numbers), starting with
      % the first function in user-land (not part of autonn).
      stack = dbstack('-completenames') ;
      
      % current file's directory (e.g. <MATCONVNET>/matlab/autonn)
      p = [fileparts(stack(1).file), filesep] ;
      
      % find a non-matching directory (i.e., not part of autonn directly)
      for i = 2:numel(stack)
        if ~strncmp(p, stack(i).file, numel(p))
          obj.source = stack(i:end) ;
          return
        end
      end
      obj.source = struct('file',{}, 'name',{}, 'line',{}) ;
    end
  end
  
  methods (Static)
    function workspaceNames(modifier)
      % LAYER.WORKSPACENAMES()
      % Sets layer names based on the name of the corresponding variables
      % in the caller's workspace. Only empty names are set.
      %
      % LAYER.WORKSPACENAMES(MODIFIER)
      % Specifies a function handle to be evaluated on each name, possibly
      % modifying it (e.g. append a prefix or suffix).
      %
      % See also SEQUENTIALNAMES.
      %
      % Example:
      %    images = Input() ;
      %    Layer.workspaceNames() ;
      %    >> images.name
      %    ans =
      %       'images'
      
      if nargin < 1, modifier = @deal ; end
      
      varNames = evalin('caller','who') ;
      for i = 1:numel(varNames)
        layer = evalin('caller', varNames{i}) ;
        if isa(layer, 'Layer') && isempty(layer.name)
          layer.name = modifier(varNames{i}) ;
        end
      end
    end
    
    function setDiagnostics(obj, value)
      if iscell(obj)  % applies recursively to nested cell arrays
        for i = 1:numel(obj)
          Layer.setDiagnostics(obj{i}, value) ;
        end
      else
        obj.diagnostics = value ;
      end
    end
    
    % overloaded native Matlab functions, static (first argument is not a
    % Layer object, call with Layer.rand(...)).
    function y = rand(obj, varargin)
      y = Layer(@rand, obj, varargin{:}) ;
    end
    function y = randi(obj, varargin)
      y = Layer(@randi, obj, varargin{:}) ;
    end
    function y = randn(obj, varargin)
      y = Layer(@randn, obj, varargin{:}) ;
    end
    function y = zeros(obj, varargin)
      y = Layer(@zeros, obj, varargin{:}) ;
    end
    function y = ones(obj, varargin)
      y = Layer(@ones, obj, varargin{:}) ;
    end
    function y = eye(obj, varargin)
      y = Layer(@eye, obj, varargin{:}) ;
    end
  end
end


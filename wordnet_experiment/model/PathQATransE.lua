require 'PathEncoder'
require 'nn'
require 'os'
require 'Print'

local PathQATransE = torch.class('PathQATransE')

function PathQATransE:__init(params)
	self.input_dim = params.input_dim
	self.relation_vocab_size = params.relation_vocab_size
	self.entity_vocab_size = params.entity_vocab_size
	self.output_dim = params.output_dim
	self.useCuda = params.useCuda
	self.saver = nil
	self.test_net = nil
	self.model_save_dir = params.model_save_dir
	self.net = self:build_network()
	self.max_h_10_dev = 0
	self.h_10_test = 0
	self.max_mq_dev = 0
	self.mq_test = 0
	-- print(self.net)

end

function PathQATransE:path_encoder()

	local p = PathEncoder(self.input_dim, self.output_dim, self.relation_vocab_size)
	local path_encoder = p:build_encoder()
	return nn.Sequential():add(path_encoder):add(nn.CAddTable())
end

function PathQATransE:entity_encoder() return nn.LookupTable(self.entity_vocab_size, self.input_dim) end

function PathQATransE:to_cuda(x) if self.useCuda then return x:cuda() else return x end end

function PathQATransE:get_network() return self.net end

function PathQATransE:build_network()
	-- body
	--data = {e1, path, e2, e_neg}
	local e1_lookup_table = self:entity_encoder()
	
	local e2_lookup_table = self:entity_encoder() --encoder for entity2

	local eneg_lookup_table = self:entity_encoder()
	
	--share params between the look up tables
	e2_lookup_table:share(e1_lookup_table,'weight', 'bias', 'gradWeight', 'gradBias')
	eneg_lookup_table:share(e1_lookup_table,'weight', 'bias', 'gradWeight', 'gradBias')	


	local path_encoder = self:path_encoder()

	local path_encoder_test = self:path_encoder()

	path_encoder_test:share(path_encoder, 'weight', 'bias', 'gradWeight', 'gradBias')

	local embeddingLayer = nn.ParallelTable()
								:add(e1_lookup_table)
								:add(path_encoder)
								:add(e2_lookup_table)
								:add(eneg_lookup_table)

	--net1, multiplies e1 and the path representation
	local add_net = nn.Sequential()
							:add(nn.NarrowTable(1,2))
							:add(nn.CAddTable()) --addition of e1 and path_repr
	
	local cat = nn.ConcatTable()
							:add(add_net)
							:add(nn.Sequential()
									:add(nn.SelectTable(3))
									:add(nn.MulConstant(-1)))
							:add(nn.Sequential()
									:add(nn.SelectTable(4))
									:add(nn.MulConstant(-1))) --  {e1+path, -e2, -e_neg}

	local dot1 = nn.Sequential()
							:add(nn.NarrowTable(1,2))
							:add(nn.CAddTable())
							:add(nn.Square())
							:add(nn.Sum(2))
							:add(nn.MulConstant(-1))
	local dot2 = nn.Sequential()
							:add(nn.ConcatTable()
										:add(nn.SelectTable(1))
										:add(nn.SelectTable(3)))
							:add(nn.CAddTable())
							:add(nn.Square())
							:add(nn.Sum(2))
							:add(nn.MulConstant(-1))

	local net = nn.Sequential()
							:add(embeddingLayer)
							:add(cat)
							:add(nn.ConcatTable()
								:add(dot1)
								:add(dot2))

	self.saver = function(i, file_name, save)
					print('Saving iteration '..i)
					file_name = self.model_save_dir..'/'..file_name..'-'..i
					if self.useCuda then --get it out of gpu before saving
						self.net:double()
					end
					local to_save = 
					{
						embedding_layer = embeddingLayer,
						path_encoder = path_encoder,
					}
					if save then torch.save(file_name, to_save) end
					if self.useCuda then --put it back
					self.net:cuda()
					end
				end
	self.test_net = function() 
		-- body
		return embeddingLayer
	end

	return net
end

function PathQATransE:initialize_net()

	if self.useCuda then self.net:cuda() end
	local params, gradParams = self.net:parameters()
	--initialization code
	local paramInit = 0.1

	--initialize the embedding matrix to uniform(-0.1, 0.1)
	params[1]:uniform(-1*paramInit, paramInit) --entity embeddings
	params[2]:uniform(-1*paramInit, paramInit) --relation embeddings

	--initialize the recurrent matrix to identity and bias to zero
	params[3]:copy(torch.eye(args.input_dim, args.output_dim))
	params[4]:copy(torch.zeros(args.output_dim))

	params[5]:copy(torch.eye(args.output_dim))
	params[6]:copy(torch.zeros(args.output_dim))
end

function PathQATransE:train(train_params)
	local train_batcher = train_params.train_batcher
	local dev_batcher = train_params.dev_batcher
	local test_batcher = train_params.test_batcher
	local learning_rate = train_params.learning_rate
	local num_epochs = train_params.num_epochs
	local grad_clip_norm = train_params.grad_clip_norm
	local criterion = self:to_cuda(train_params.criterion)
	local beta1 = train_params.beta1
	local beta2 = train_params.beta2
	local epsilon = train_params.epsilon
	local optim_method = train_params.optim_method

	local opt_config = {
		learning_rate = learning_rate,
		beta1 = beta1,
		beta2 = beta2,
		epsilon = epsilon
}	

	local configs= {
	grad_clip_norm = grad_clip_norm,
	opt_config = opt_config,
	opt_state = {},
	optim_method = optim_method
	}
	self.net:training()
	local prevTime = sys.clock()
	local numProcessed = 0
	--count the total number of batches once. This is for displpaying the progress bar; helps to track time
    local total_batches = 0
    print('Making a pass of the data to count the batches')
    while(true) 
    do
        local batch_data = train_batcher:get_batch()
        if batch_data == nil then break end
        total_batches = total_batches + 1
    end
    print('Total num batches '..total_batches)
	train_batcher:reset()
	local epoch_counter = 0
	local batch_counter = 0
	local running_err = 0
	while epoch_counter < num_epochs do
		while(true) do
			local batch_data = train_batcher:get_batch()
			if batch_data == nil then break end
			if self.useCuda then
				--batch_data looks like {e1_tensor, paths_tensor, e2_tensor, e_neg_tensor}
				batch_data = {batch_data[1]:cuda(), batch_data[2]:cuda(), batch_data[3]:cuda(), batch_data[4]:cuda()}
			end
			local targets = self:to_cuda(batch_data[1]:clone():fill(1)) --generating fake labels

			local batch_err = self:train_batch(batch_data, targets, criterion, configs)
			running_err = running_err + batch_err
			batch_counter = batch_counter + 1
			if batch_counter % 100 == 0 then
				print('Iteration '..epoch_counter..'; batch number '..batch_counter..'; running error '..running_err/batch_counter..'\r')
				self:check_performance(dev_batcher, test_batcher)
				-- call saver
				-- self.saver(batch_counter, 'model', true)
				-- io.write(string.format('\rIteration %d\t batch %d\trunning_err %.8f',epoch_counter,batch_counter,running_err/batch_counter))
				-- io.flush()
			end
			-- xlua.progress(batch_counter, total_batches)

			if batch_counter == 4500 then
				print('Exiting after 4500 gradient steps')
				print('h@10 (test) after tuning dev set is '..self.h_10_test)
				print('MQ (test) after tuning dev set is '..self.mq_test)				
				os.exit(1)
			end

		end
		epoch_counter = epoch_counter + 1
		train_batcher:reset()
	end	
	print('h@10 (test) after tuning dev set is '..self.h_10_test)
	print('MQ (test) after tuning dev set is '..self.mq_test)	
end

function PathQATransE:train_batch(inputs, targets, criterion, configs)
	-- body
	assert(inputs)
    assert(targets)
    local params, grad_params = self.net:getParameters() -- this method returns a tensor
    local err = nil
    local function fEval(x)
    	if params ~= x then params:copy(x) end
        self.net:zeroGradParameters()
        local output = self.net:forward(inputs)
        err = criterion:forward(output, targets)
        local df_do = criterion:backward(output, targets)
        self.net:backward(inputs, df_do)
        local norm = grad_params:norm()
        if norm > configs.grad_clip_norm then
        	grad_params:mul(configs.grad_clip_norm/norm)
        end
        return err, grad_params
    end
    configs.optim_method(fEval, params, configs.opt_config, configs.opt_state)
    return err
end

function PathQATransE:check_performance(batcher, test_batcher)
	print('Checking performance...')


	local embedding_layer = self:test_net()
	
	local test_net = nn.Sequential()
								:add(embedding_layer)
								:add(nn.NarrowTable(1,2))
								:add(nn.CAddTable())

	if self.useCuda then test_net:cuda() end

	local params, gradParams = embedding_layer:parameters()
	local embedding_mat = params[1] -- this is vocab X dim

	local get_performance = function(batcher)
		local h_at_10 = 0
		local mq = 0 --mean quantile
		local num_data = 0
		while(true) do
			local batch_data = batcher:get_batch()
			if batch_data == nil then break end
			
			local negative_examples_indexes = nil
			local num_negative_examples = nil
			if self.useCuda then
				--batch_data looks like {e1_tensor, paths_tensor}
				batch_data = {batch_data[1]:cuda(), batch_data[2]:cuda(), batch_data[3]:cuda(), batch_data[4]:cuda(), batch_data[5]:cuda(), batch_data[6]:cuda()}
				negative_examples_indexes = batch_data[5] --this is batch_size X vocab
				num_negative_examples = batch_data[6] -- this is batch_size
			end
			local e2 = batch_data[3]
			e1_path = test_net(batch_data) --  this is batch_size X dim
			--create a new view which is batch_size X 1 X dim
			e1_path = e1_path:view(e1_path:size(1), 1, e1_path:size(2))
			--expand it vocabulary number of times -- batch_size X vocab_size X dim
			e1_path = e1_path:expand(e1_path:size(1), self.entity_vocab_size , e1_path:size(3))
			--expand emebdding matrix to batch_size X vocab_size X dim
			-- emebedding_mat is vocab_size is dim
			embedding_mat1 = embedding_mat:view(1, embedding_mat:size(1), embedding_mat:size(2))
			embedding_mat1 = embedding_mat1:expand(e1_path:size(1),embedding_mat:size(1), embedding_mat:size(2))

			-- local scores = torch.mm(e1_path, embedding_mat:t()) -- scores is batch_size X vocab
			local diff = e1_path - embedding_mat1 --batch_size X vocab_size X dim
			--Now the next step is to get the euclidean distance
			local diff_square = self:to_cuda(nn.Square())(diff) -- batch_size X vocab_size X dim

			local scores = torch.sum(diff_square, 3):squeeze() -- scores is batch_size X vocab
			scores = scores:mul(-1)
			local filtered_score_mat = self:get_filtered_scores(scores, negative_examples_indexes)
			h_at_10 = h_at_10 + self:calculate_hits_at_10(filtered_score_mat, e2)
			mq = mq + self:quantile(filtered_score_mat, num_negative_examples, e2)
			num_data = num_data + e2:size(1)

		end	
		batcher:reset() -- for the next iter
		return h_at_10/ num_data, mq/num_data
	end

	h_at_10_dev, mq_dev = get_performance(batcher)
	print('hits@10 (dev) '..h_at_10_dev)
	print('Mean Quantile (dev) '..mq_dev)
	if h_at_10_dev > self.max_h_10_dev then
		self.max_h_10_dev = h_at_10_dev
		self.h_10_test, _ = get_performance(test_batcher)
	end

	if mq_dev > self.max_mq_dev then
		self.max_mq_dev = mq_dev
		_, self.mq_test = get_performance(test_batcher)
	end
	--calculate for test data; dont print it out

end

function PathQATransE:get_filtered_scores(scores, negative_examples_indexes)
	--takes in the original batch_size X entity_vocab score matrix; returns an batch_size X entity_vocab matrix
	-- But it retains the score of only the precomputed negative entities for a given test entity (in each row)
	-- rest all are assigned as -inf

	--1. add a column to the score matrix and fill it with -inf, This is because the entities which are not negative entities all point to this extra col
	local scores_extended = self:to_cuda(torch.zeros(scores:size(1), scores:size(2)+1):fill('-inf'))
	scores_extended:narrow(2, 1, scores:size(2)):copy(scores) --only last column is -inf
	
	--2. Use gather method of tensor to gether the scores of just the negative entities and rest would be filled by -inf from the last col
	local filtered_score_mat = scores_extended:gather(2, negative_examples_indexes)	

	return filtered_score_mat

end

-- For a query q,the quantile of a correct answer t is the fraction of incorrect answers ranked after t (Guu, 2015)
-- e2 are the target entities
function PathQATransE:quantile(filtered_scores, num_negative_examples, e2)
	--1. gather the scores of the target entities
	local score_target_entities = filtered_scores:gather(2, e2:view(e2:size(1), 1))
	--2. Calculate for each entity the quantile. score_target_entities is batch_size X 1
	local score_target_entities_expanded = score_target_entities:expandAs(filtered_scores) -- doesnt use extra mem
	--3. Get the number of entities which have scored greater than the tatget entities
	local num_greater = self:to_cuda(torch.gt(filtered_scores, score_target_entities_expanded):sum(2)) --sums each row
	--4. Divide the num_megative_examples
	local ratio = num_greater:cdiv(num_negative_examples:view(num_negative_examples:size(1),1))
	--5 quantile is 1 - ratio
	local quantile = 1 - ratio

	--return sum
	return quantile:sum()


end

-- e2 are the target entities
function PathQATransE:calculate_hits_at_10(filtered_scores, e2)
	local k = 10
	--1. get the top-k for each row
	local top_k_scores, index = torch.topk(filtered_scores, k, 2, true) --top_k_scores, index is batch X k
	-- 2. expand e2
	local e2_expanded = e2:view(e2:size(1),1):expandAs(index)
	--3. if e2 is there row would be 1 else all 0's
	--Looks like cuda tensors dont have map method; well, convert to double
	index = index:double()
	e2_expanded = e2_expanded:double()
	index:map(e2_expanded, function(x,y) if x == y then return 1 else return 0 end end) -- each row will contain atmost one 1
	--4. sum the tensor
	return torch.sum(index) -- sum all the 1's

end
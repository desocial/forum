contract Token {
	mapping (address => uint256) balances;
    //mapping (address => mapping (address => uint256)) allowed;

    uint256 public totalSupply;
	
	/*event Transfer(address indexed _from, address indexed _to, uint256 _amount);
    event Approval(
        address indexed _owner,
        address indexed _spender,
        uint256 _amount
    );*/

    function balanceOf(address _owner) constant returns (uint256 balance) {
        return balances[_owner];
    }

	// Transfering balances is not needed, since people can always withdraw / buy tokens.
	// This makes it simplier so no checks are needed to check risked funds.
	/*
    function transfer(address _to, uint256 _amount) returns (bool success) {
        if (balances[msg.sender] >= _amount && _amount > 0) {
            balances[msg.sender] -= _amount;
            balances[_to] += _amount;
            Transfer(msg.sender, _to, _amount);
            return true;
        } else {
           return false;
        }
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) returns (bool success) {

        if (balances[_from] >= _amount
            && allowed[_from][msg.sender] >= _amount
            && _amount > 0) {

            balances[_to] += _amount;
            balances[_from] -= _amount;
            allowed[_from][msg.sender] -= _amount;
            Transfer(_from, _to, _amount);
            return true;
        } else {
            return false;
        }
    }

    function approve(address _spender, uint256 _amount) returns (bool success) {
        allowed[msg.sender][_spender] = _amount;
        Approval(msg.sender, _spender, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) constant returns (uint256 remaining) {
        return allowed[_owner][_spender];
    }
	*/
}

contract SocialBoard is Token {
	address public curator;
	// This is the funds this account has risked, risking is a show of trust that if you are wrong then you may loose this amount.
	// All accounts risks funds class for more points on voting, posting, etc. However they may not be withdrawn if they are bad within this time.
	mapping(address => uint256) public riskedFunds;
	mapping(address => LockedUntil[]) public lockedFunds;
	Board[] boards;
	// The required length for a message to prevent 0 length and short messages.
	uint256 constant public MIN_MESSAGE_LENGTH = 4;
	uint256 constant public MIN_TOPIC_LENGTH = 6;
	uint256 constant public AUTO_TOPIC_LOCK = 2592000; // If a topic has not been updated for one month no more posts can be made.
	uint256 constant public FUND_LOCK_PERIOD = 604800; // Risked Funds are locked for 7 days, non risked funds may be withdrawn at any time.
	
	struct Board {
		string name;
		Topic[] topics;
		// Special is basically a special section.
		// 0 = nothing
		// 1 = only curator can make topics
		uint8 special;
		// This is the required risked to be able to post a topic in this board, this can be used for marketplace or for higher ranking members who want to trust who they are talking to.
		uint256 minimumRisk;
		uint256 created;
		uint256 updated;
	}
	
	struct Topic {
		string name;
		address poster;
		Post[] posts;
		uint256 created;
		uint256 updated;
	}
	
	struct Post {
		address poster;
		string message;
		uint256 upvotes;
		uint256 downvotes;
		Vote[] votes;
		address[] attachedFiles;
		uint256 created;
	}
	
	struct Vote {
		address voter;
		uint256 amount;
		bool upvote;
	}
	
	struct LockedUntil {
		uint256 amount;
		uint256 unlocks;
	}

	event curatorChanged(address oldCurator, address newCurator);
	event fundsRisked(address account, uint256 amount);
	event riskedFundsLost(address account, uint256 amount, bool transferred);
	event boardAdded(string name, uint8 special, uint256 minimumRisk);
	
	// This allows if a user sends ether to credit it to their account.
	modifier creditEther() {
		if (msg.value > 0)
			depositAccount(msg.sender);
		_
	}
	
	function SocialBoard(address _curator) {
		curator = _curator;
	}
	
	// This is used to change the owner, in the future it will be put into a multi trust DAO.
	function changeCurator(address _newCurator) creditEther returns (bool success) {
		if (msg.sender != curator)
			return false;
		
		curator = _newCurator;
		curatorChanged(msg.sender, _newCurator);
		return true;
	}
	
	// This creates a new board, only for curator.
	function createBoard(string _name, uint8 _special, uint256 _minimumRisk) creditEther returns (bool success) {
		if (msg.sender != curator)
			return false;
		
		uint256 boardId = boards.length++;
		Board board = boards[boardId];
		board.name = _name;
		board.special = _special;
		board.minimumRisk = _minimumRisk;
		board.created = now;
		board.updated = now;
		boardAdded(_name, _special, _minimumRisk);
		return true;
	}
	
	// This function allows an account to loose their risked funds, this should be used at times of users being untrustworthy in privileged sections, like a marketplace.
	// Either the funds will be burned (kept by the contract) or they will be transferred to the curators balance which then can be used to pay back users / donate to charity.
	function looseRisked(address _account, uint256 _amount, bool _transfer) creditEther returns (bool success) {
		if (msg.sender != curator || 
			riskedFunds[_account] < _amount)
			return false;
		
		riskedFunds[_account] -= _amount;
		balances[_account] -= _amount;
		
		if (_transfer) {
			balances[curator] += _amount;
		}
		
		riskedFundsLost(_account, _amount, _transfer);
		return true;
	}
	
	// This allows a user to vote by risking their funds and locking them for 7 days.
	// Each user can use only the funds from their account and only once not on every post/topic.
	// To vote on a topic the _post should be = 0, as that is the post the user made along with the topic.
	/*
	Error codes
	2 = post could not be found.
	3 = you have already voted on this post/topic
	4 = was unable to apply risk because we do not have enough risk free balance.
	*/
	function vote(uint256 _board, uint256 _topic, uint256 _post, uint256 _voteAmt, bool _upVote) creditEther returns (uint256 error) {
		if (_board > boards.length || 
			_topic > boards[_board].topics.length || 
			_post > boards[_board].topics[_topic].posts.length)
			return 2;
		
		Post post = boards[_board].topics[_topic].posts[_post];
		
		// Check to make sure we have not already voted on this topic.
		uint256 voters = post.votes.length;
		for (uint256 i = 0; i < voters; i++) {
			if (post.votes[i].voter == msg.sender)
				return 3;
		}
		
		// Risk the funds, make sure we have enough.
		if (!applyRisk(msg.sender, _voteAmt))
			return 4;
		
		// Now record our vote, and add it to the score.
		uint256 myVoteId = post.votes.length++;
		Vote vote = post.votes[myVoteId];
		vote.voter = msg.sender;
		vote.amount = _voteAmt;
		vote.upvote = _upVote;
		
		return 1;
	}
	
	/*
	Error codes
	please also look at post error codes (should not happen)
	4 = board not found
	5 = unable to post because only curator is allowed to make topics
	6 = was unable to apply risk because we do not have enough risk free balance.
	*/
	function createTopic(uint256 _board, string _name, string _message, address[] _attachedFiles) creditEther returns (uint256 error) {
		if (_board > boards.length)
			return 4;
		
		Board board = boards[_board];
		// Check board specials, if we are allowed to make a topic in this board?
		if (board.special == 1 && msg.sender != curator)
			return 5;
		
		// A check to make sure we have enough risk for this section.
		if (board.minimumRisk > 0/* && riskedFunds[msg.sender] < board.minimumRisk*/) {
			// If we have enough balance to cover it we can move those funds into risked so we can create a topic.
			// This becomes a little tricky because we can either just make them risk all they need, or we can make them risk the same amount each topic.
			// The problem with making them only risk once is that it opens a couple of exploits. Applying a risk waiting until it is ready to be unlocked then they can withdraw a will.
			// While requiring them to risk more each time does solve the above issue, it only guarentees it for a short time.
			uint256 riskNeeded = board.minimumRisk /* - riskedFunds[msg.sender] */;
			if (!applyRisk(msg.sender, riskNeeded))
				return 6;
		}
		
		board.updated = now;
		uint256 topicId = board.topics.length++;
		Topic topic = board.topics[topicId];
		topic.name = _name;
		topic.poster = msg.sender;
		topic.created = now;
		topic.updated = now; // This is needed otherwise the check if the thread should be locked will always fail.
		
		// No worries about not being created because the two issues should not be possible on a new topic.
		return createPostInternal(msg.sender, _board, topicId, _message, _attachedFiles);
	}
	
	// This is needed because the createTopic also uses this logic as well as createPost and if we just called it directly it would use the contract address with msg.sender.
	/*
	Error codes
	2 = topic was not found
	3 = it has been too long since last reply on topic.
	*/
	function createPostInternal(address _user, uint256 _board, uint256 _topic, string _message, address[] _attachedFiles) internal returns (uint256 error) {
		if (_board > boards.length || 
			_topic > boards[_board].topics.length)
			return 2;
		
		Topic topic = boards[_board].topics[_topic];
		
		// Check to make sure that the thread is not auto_locked due to too much time without any replies.
		if (topic.updated + AUTO_TOPIC_LOCK < now)
			return 3;
		
		topic.updated = now;
		uint256 postId = topic.posts.length++;
		Post post = topic.posts[postId];
		post.poster = _user;
		post.message = _message;
		post.created = now;
		post.attachedFiles = _attachedFiles;
		
		return 1;
	}
	
	function createPost(uint256 _board, uint256 _topic, string _message, address[] _attachedFiles) creditEther returns (uint256 error) {
		return createPostInternal(msg.sender, _board, _topic, _message, _attachedFiles);
	}
	
	// Allow deposit into an external account.
	function depositAccount(address _account) {
		
		// Prevent not entering an address / amount.
		if (_account == 0 || msg.value == 0)
			return;
		
		balances[_account] += msg.value;
		totalSupply += msg.value;
	}
	
	// Allow the user to withdraw their stored funds at any time.
	/*
	 Error codes:
	 2 = Risked funds are higher than balance.
	 3 = amt is either zero including the riskedfunds.
	 4 = send failed, most likely due to the receiving contract error / oog.
	 */
	function withdraw(uint256 _amt, bool _all) creditEther returns (uint256 error) {
		if (_all)
			_amt = balanceOf(msg.sender) - riskedFunds[msg.sender];
		
		if (riskedFunds[msg.sender] > balanceOf(msg.sender))
			return 2;
		
		if (_amt == 0 || _amt > balanceOf(msg.sender) - riskedFunds[msg.sender])
			return 3;

		// Should be safe using send with the included 2300 gas. At current gas prices a callvalue = 9000, also the 2 SStores which are at least 10000.
		if (!msg.sender.send(_amt))
			return 4;
		
		balances[msg.sender] -= _amt;
		totalSupply -= _amt;
		return 1;
	}
	
	// Allow users to deposit funds into their account balance, always allowed.
	function () {
		depositAccount(msg.sender);
	}
	
	// This function will try to unlock the risked funds if it has past the deadline.
	/*
	Error codes
	2 = there is nothing locked.
	3 = nothing was unlocked.
	*/
	function unlockRisked() creditEther returns (uint256 error) {
		uint256 lockedCount = lockedFunds[msg.sender].length;
		// Just prevent if nothing is locked with an error.
		if (lockedCount == 0)
			return 2;
		
		for(uint256 i=0; i<lockedCount; ) {
			LockedUntil locked = lockedFunds[msg.sender][i];
			if (locked.unlocks <= now) {
				// This can happen if their risk funds are revoked, to prevent overflow just give them all remaining funds.
				if (locked.amount > riskedFunds[msg.sender]) {
					riskedFunds[msg.sender] = 0;
				} else {
					riskedFunds[msg.sender] -= locked.amount;
				}
				lockedCount--;
				delete lockedFunds[msg.sender][i];
				continue;
			}
			// Since each deletion shifts the array, only increment if nothing is removed.
			i++;
		}
		
		if (lockedCount == lockedFunds[msg.sender].length)
			return 3;
		
		return 1;
	}
	
	// If the user wants they can risk any amount of funds they wish, this is typically done automatically depending on the board if they have enough balance.
	function riskFunds(uint256 _amount) creditEther returns (bool success) {
		return applyRisk(msg.sender, _amount);
	}
	
	// This function puts the risk on the user to say that they are willing to risk that amount.
	// This way if a user is not trustworthy they can be punished by loosing their risked funds.
	// This only applies to sections in which minimumRisk > 0, otherwise this is never used unless optionally with riskFunds.
	function applyRisk(address _addr, uint256 _amount) internal returns (bool success) {
		if (balanceOf(_addr)-riskedFunds[_addr] >= _amount) {
			riskedFunds[_addr] += _amount;
			uint256 lockedId = lockedFunds[_addr].length++;
			LockedUntil locked = lockedFunds[_addr][lockedId];
			locked.amount = _amount;
			locked.unlocks = now + FUND_LOCK_PERIOD;
			fundsRisked(_addr, _amount);
			return true;
		}
		return false;
	}
	
	// All of these functions below are to ease integration with reading data through solidity or web3.
	// If web3 supported structs these would likely not be required, but now for they are.
	
	function getBoardLength() public constant returns(uint256) {
        return boards.length;
    }
	
    function getBoard(uint256 boardId) public constant returns(string, uint8, uint256, uint256, uint256) {
		Board b = boards[boardId];
        return (b.name, b.special, b.minimumRisk, b.created, b.updated);
    }

	function getTopicLength(uint256 boardId) public constant returns (uint256) {
		return boards[boardId].topics.length;
	}
	
	function getTopic(uint256 boardId, uint256 topicId) public constant returns(string, address, uint256, uint256) {
		Topic t = boards[boardId].topics[topicId];
        return (t.name, t.poster, t.created, t.updated);
    }
	
	function getPostLength(uint256 boardId, uint256 topicId) public constant returns (uint256) {
		return boards[boardId].topics[topicId].posts.length;
	}
	
	function getPost(uint256 boardId, uint256 topicId, uint256 postId) public constant returns(address, string, uint256, uint256, address[], uint256) {
		Post p = boards[boardId].topics[topicId].posts[postId];
        return (p.poster, p.message, p.upvotes, p.downvotes, p.attachedFiles, p.created);
    }
	
	function getVoteLength(uint256 boardId, uint256 topicId, uint256 postId) public constant returns (uint256) {
		return boards[boardId].topics[topicId].posts[postId].votes.length;
	}
	
	function getVote(uint256 boardId, uint256 topicId, uint256 postId, uint256 voteId) public constant returns(address, uint256, bool) {
		Vote v = boards[boardId].topics[topicId].posts[postId].votes[voteId];
		return (v.voter, v.amount, v.upvote);
	}

}
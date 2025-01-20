use starknet::{ContractAddress};

#[starknet::interface]
pub trait IDuckPrediction<TContractState> {
    fn create(
        ref self: TContractState, description: ByteArray, bet_duration: u64, close_timestamp: u64,
    );

    fn bet(ref self: TContractState, id: u128, direction: bool, amount: u256);

    fn assert(ref self: TContractState, id: u128, result: bool);

    fn dispute(ref self: TContractState, id: u128);

    fn settle(ref self: TContractState, id: u128);

    fn owner_settle(ref self: TContractState, id: u128, result: bool);

    fn claim(ref self: TContractState, id: u128);

    fn get_round_info(self: @TContractState, id: u128) -> Round;

    fn get_user_position(self: @TContractState, id: u128, user: ContractAddress) -> UserPosition;

    fn get_current_round_id(self: @TContractState) -> u128;

    fn approve_to_oo(ref self: TContractState, amount: u256);

    fn get_bond(self: @TContractState) -> u256;

    fn get_oo_assert_fee(self: @TContractState) -> u256;

}


#[starknet::interface]
pub trait IOptimisticOracleCallbackRecipient<TContractState> {
    fn assertion_resolved_callback(
        ref self: TContractState, assertion_id: felt252, asserted_truthfully: bool
    );

    fn assertion_disputed_callback(ref self: TContractState, assertion_id: felt252);
}


#[derive(Drop, Copy, Serde, PartialEq, starknet::Store)]
pub enum RoundOutcome {
    Pending,
    Asserting,
    Yes,
    No,
    Uncertain
}


#[derive(Drop, Serde, starknet::Store)]
pub struct UserPosition {
    yes_amount: u256,
    no_amount: u256,
    rewards_claimed: bool,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct Round {
    initiator: ContractAddress,
    description: ByteArray,
    start_timestamp: u64,
    lock_timestamp: u64,
    close_timestamp: u64,
    yes_amount: u256,
    no_amount: u256,
    total_amount: u256,
    reward_pool_amount: u256,
    round_outcome: RoundOutcome,
    assert_id: felt252,
    resolved: bool,
}


#[starknet::contract]
mod DuckPrediction {
    use contracts::interfaces::{IOptimisticOracleDispatcher, IOptimisticOracleDispatcherTrait};

    use core::starknet::storage::{Map};

    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use pragma_lib::abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use pragma_lib::types::DataType;

    use alexandria_math::pow;

    use starknet::{
        ContractAddress, get_block_timestamp, contract_address_const, get_caller_address,
        get_contract_address
    };

    use super::{
        IDuckPrediction, IOptimisticOracleCallbackRecipient, RoundOutcome, Round, UserPosition
    };

    // CONSTANTS DEFINITION
    pub const ASSERTION_LIVENESS: u64 = 150;
    pub const ASSERTION_FEE: u128 = 100000000;


    pub const BET_TOKEN_ADDRESS: felt252 =
        0x019be8d7ed4b93a4e924218a0d3e08abf0b33623d655b9c04197eb189c3f3d8c;
    pub const ETH_ADDRESS: felt252 =
        0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7;
    pub const OO_ADDRESS: felt252 =
        0x044ac84b04789b0a2afcdd2eb914f0f9b767a77a95a019ebaadc28d6cacbaeeb;
    pub const ORACLE_ADDRESS: felt252 =
        0x36031daa264c24520b11d93af622c848b2499b66b41d611bac95e13cfca131a;


    #[storage]
    struct Storage {
        owner: ContractAddress,
        rounds: Map<u128, Round>,
        round_id: u128,
        bet_token: ERC20ABIDispatcher,
        bond_token: ERC20ABIDispatcher,
        reward: u256, // settle reward
        bond: u256, // oralce 
        settlement_buffer: u64,
        platform_fee_rate: u256,
        user_positions: Map<(u128, ContractAddress), UserPosition>,
        asserted_markets: Map<
            felt252, (ContractAddress, u128, bool)
        >, // assert id ==> asserter, round_id, result
        default_identifier: felt252,
        oo: IOptimisticOracleDispatcher,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
        self.round_id.write(0);

        self
            .bet_token
            .write(
                ERC20ABIDispatcher { contract_address: BET_TOKEN_ADDRESS.try_into().unwrap() }
            ); // GT
        self
            .bond_token
            .write(ERC20ABIDispatcher { contract_address: ETH_ADDRESS.try_into().unwrap() }); // ETH

        self.settlement_buffer.write(100);
        self.platform_fee_rate.write(100);

        self
            .oo
            .write(
                IOptimisticOracleDispatcher { contract_address: OO_ADDRESS.try_into().unwrap() }
            );
        let di = self.oo.read().default_identifier();
        self.default_identifier.write(di);

        let minimum_bond = self.oo.read().get_minimum_bond(ETH_ADDRESS.try_into().unwrap());
        self.bond.write(minimum_bond);
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        RoundCreated: RoundCreated,
        BetPlaced: BetPlaced,
        RoundAsserted: RoundAsserted,
        RoundSettled: RoundSettled,
        RewardClaimed: RewardClaimed,
    }

    #[derive(Drop, starknet::Event)]
    struct RoundCreated {
        id: u128,
        initiator: ContractAddress,
        description: ByteArray,
        lock_timestamp: u64,
        close_timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct BetPlaced {
        round_id: u128,
        user: ContractAddress,
        direction: bool,
        amount: u256,
    }


    #[derive(Drop, starknet::Event)]
    struct RoundAsserted {
        round_id: u128,
        asserted_outcome: bool,
        assert_endtime: u64,
    }


    #[derive(Drop, starknet::Event)]
    struct RoundSettled {
        round_id: u128,
        is_resoloved: bool,
        outcome: RoundOutcome,
    }

    #[derive(Drop, starknet::Event)]
    struct RewardClaimed {
        round_id: u128,
        user: ContractAddress,
        amount: u256,
    }


    #[abi(embed_v0)]
    impl IOptimisticOracleCallbackRecipientImpl of IOptimisticOracleCallbackRecipient<
        ContractState
    > {
        fn assertion_resolved_callback(
            ref self: ContractState, assertion_id: felt252, asserted_truthfully: bool
        ) {
            assert(get_caller_address() == self.oo.read().contract_address, 'NOT AUTHORIZED');

            if (asserted_truthfully) {
                let (asserter, round_id, res) = self.asserted_markets.read(assertion_id);
                let mut round = self.rounds.read(round_id);
                round.resolved = true;

                // Calculate platform fee
                let platform_fee_rate = self.platform_fee_rate.read();
                let platform_fee = round.total_amount
                    * platform_fee_rate
                    / 10000; // Rate is in basis points

                // Calculate actual reward pool
                round.reward_pool_amount = round.total_amount - platform_fee;

                // Transfer platform fee to owner
                if platform_fee > 0 {
                    let token = self.bet_token.read();
                    token.transfer(self.owner.read(), platform_fee);
                }

                if (res) {
                    round.round_outcome = RoundOutcome::Yes;
                    self.emit(RoundSettled { round_id, is_resoloved: true, outcome: RoundOutcome::Yes });
                } else {
                    round.round_outcome = RoundOutcome::No;
                    self.emit(RoundSettled { round_id, is_resoloved: true, outcome: RoundOutcome::No });
                }

                self.rounds.write(round_id, round);
            }
        }


        fn assertion_disputed_callback(ref self: ContractState, assertion_id: felt252) {
            assert(get_caller_address() == self.oo.read().contract_address, 'NOT AUTHORIZED');

            let (asserter, round_id, res) = self.asserted_markets.read(assertion_id);
            let mut round = self.rounds.read(round_id);

            round.round_outcome = RoundOutcome::Uncertain;
            self.rounds.write(round_id, round);

            self.emit(RoundSettled { round_id, is_resoloved: false, outcome: RoundOutcome::Uncertain });
        }
    }


    #[abi(embed_v0)]
    impl DuckPrediction of IDuckPrediction<ContractState> {
        // --
        fn create(
            ref self: ContractState,
            description: ByteArray,
            bet_duration: u64,
            close_timestamp: u64,
        ) {
            // Get current timestamp
            let current_time = get_block_timestamp();

            // Validate timestamps
            let lock_timestamp = current_time + bet_duration;
            assert(lock_timestamp < close_timestamp, 'Invalid lock time');

            // transfer reward and bond here

            let round = Round {
                initiator: get_caller_address(),
                description: description.clone(),
                start_timestamp: current_time,
                lock_timestamp,
                close_timestamp,
                yes_amount: 0,
                no_amount: 0,
                total_amount: 0,
                reward_pool_amount: 0,
                round_outcome: RoundOutcome::Pending,
                assert_id: 0,
                resolved: false,
            };

            // Store round
            let round_id = self.round_id.read();
            self.rounds.write(round_id, round);
            self.round_id.write(round_id + 1);

            self
                .emit(
                    RoundCreated {
                        id: round_id,
                        initiator: get_caller_address(),
                        description: description.clone(),
                        lock_timestamp,
                        close_timestamp,
                    }
                );
        }


        // --
        fn bet(ref self: ContractState, id: u128, direction: bool, amount: u256) {
            // Get round
            let mut round = self.rounds.read(id);

            // Validate timing
            let current_time = get_block_timestamp();
            assert(current_time < round.lock_timestamp, 'Round locked');
            assert(round.round_outcome == RoundOutcome::Pending, 'Round finished');
            assert(amount > 0, 'Amount 0');

            // Transfer tokens
            let caller = get_caller_address();
            let token = IERC20Dispatcher { contract_address: self.bet_token.read() };
            token.transfer_from(caller, get_contract_address(), amount);

            // Update round amounts
            if direction {
                round.yes_amount += amount;
            } else {
                round.no_amount += amount;
            }
            round.total_amount += amount;

            // Update user position
            let mut position = self.user_positions.read((id, caller));
            if direction {
                position.yes_amount += amount;
            } else {
                position.no_amount += amount;
            }
            self.user_positions.write((id, caller), position);

            // Update round
            self.rounds.write(id, round);

            // Emit event
            self.emit(BetPlaced { round_id: id, user: caller, direction, amount });
        }

        // --
        fn assert(ref self: ContractState, id: u128, result: bool) {
            // Get round
            let mut round = self.rounds.read(id);

            // Validate timing
            let current_time = get_block_timestamp();
            assert(current_time >= round.close_timestamp, 'Too early to settle');
            assert(
                current_time <= round.close_timestamp + self.get_settlement_buffer(),
                'Round expired'
            );
            assert(round.round_outcome == RoundOutcome::Pending, 'Already settled');
            assert(result != RoundOutcome::Pending, 'Result error');

            // Transfer bond here
            let caller = get_caller_address();
            let bond_contract = self.bond_token.read();
            bond.transfer_from(caller, get_contract_address(), self.bond.read() );

            // claim
            let mut claim_input: ByteArray = Default::default();
            if result {
                claim_input = "Yes";
            } else {
                claim_input = "No";
            }
            let claim = compose_claim(claim_input, round.description.clone());

            bond_contract.approve(self.oo.read().contract_address, 1_000_000_000_000_000_000);

            // approve
            let assertion_id = self.assert_thruth_with_defaults(claim, self.bond.read());

            //
            self.asserted_markets.write(assertion_id, (get_caller_address(), id, result));

            round.round_outcome = RoundOutcome::Asserting;
            round.assert_id = assertion_id;
            self.rounds.write(id, round);

            self
                .emit(
                    RoundAsserted {
                        round_id: id,
                        asserted_outcome: result,
                        assert_endtime: get_block_timestamp() + ASSERTION_LIVENESS
                    }
                );
        }


        fn dispute(ref self: ContractState, id: u128) {
            let mut round = self.rounds.read(id);

            let assert_id = round.assert_id;
            assert(assert_id != 0, 'not assert');

            let bond_contract = self.bond_token.read();
            bond_contract.approve(self.oo.read().contract_address, 1_000_000_000_000_000_000);

            let oo = self.oo.read();
            oo.dispute_assertion(assert_id, get_caller_address());
        }

        fn settle(ref self: ContractState, id: u128) {
            let mut round = self.rounds.read(id);

            assert(round.round_outcome != RoundOutcome::Uncertain, 'not uncertain');

            let assert_id = round.assert_id;
            assert(assert_id != 0, 'not assert');

            let oo = self.oo.read();
            oo.settle_assertion(assert_id);
        }


        fn owner_settle(ref self: ContractState, id: u128, result: bool) {
            let mut round = self.rounds.read(id);

            assert(owner == get_caller_address(), 'nnot owner');
            assert(round.round_outcome == RoundOutcome::Uncertain, 'not uncertain');


            // Calculate platform fee
            let platform_fee_rate = self.platform_fee_rate.read();
            let platform_fee = round.total_amount
                * platform_fee_rate
                / 10000; // Rate is in basis points

            // Calculate actual reward pool
            round.reward_pool_amount = round.total_amount - platform_fee;

            // Transfer platform fee to owner
            if platform_fee > 0 {
                let token = self.bet_token.read();
                token.transfer(self.owner.read(), platform_fee);
            }

            round.resolved = true;
            if (result) {
                round.round_outcome = RoundOutcome::Yes;
                self.emit(RoundSettled { round_id: id, is_resoloved: true, outcome: RoundOutcome::Yes });
            } else {
                round.round_outcome = RoundOutcome::No;
                self.emit(RoundSettled { round_id: id, is_resoloved: true, outcome: RoundOutcome::No });
            }

            self.rounds.write(id, round);
            
        }


        fn claim(ref self: ContractState, id: u128) {
            let round = self.rounds.read(id);
            assert(round.resolved, 'Round not resoloved');

            let caller = get_caller_address();
            let mut position = self.user_positions.read((id, caller));
            assert(!position.rewards_claimed, 'Already claimed');

            let reward_amount = match round.round_outcome {
                RoundOutcome::Yes => {
                    if position.yes_amount > 0 {
                        position.yes_amount * round.reward_pool_amount / round.yes_amount
                    } else {
                        0
                    }
                },
                RoundOutcome::No => {
                    if position.no_amount > 0 {
                        position.no_amount * round.reward_pool_amount / round.no_amount
                    } else {
                        0
                    }
                },
                RoundOutcome::Asserting => panic!("Round not resoloved"),
                RoundOutcome::Uncertain => panic!("Round not resoloved"),
                RoundOutcome::Pending => panic!("Round not resoloved")
            };

            if reward_amount > 0 {
                let token = self.bet_token.read();
                token.transfer(caller, reward_amount);
            }

            position.rewards_claimed = true;
            self.user_positions.write((id, caller), position);

            self.emit(RewardClaimed { round_id: id, user: caller, amount: reward_amount });
        }

        fn get_round_info(self: @ContractState, id: u128) -> Round {
            let round = self.rounds.read(id);
            assert(round.initiator != contract_address_const::<0>(), 'Round not found');
            round
        }

        fn get_user_position(
            self: @ContractState, id: u128, user: ContractAddress
        ) -> UserPosition {
            let round = self.rounds.read(id);
            assert(round.initiator != contract_address_const::<0>(), 'Round not found');
            self.user_positions.read((id, user))
        }

        fn get_current_round_id(self: @ContractState) -> u128 {
            let round_id = self.round_id.read();
            assert(round_id > 0, 'No rounds created');
            round_id - 1
        }

        fn approve_to_oo(ref self: ContractState, amount: u256) {
            let bond = self.bond_token.read();
            bond.approve(self.oo.read().contract_address, amount);
        }

        fn get_bond(self: @ContractState) -> u256 {
            self.bond.read()
        }

        fn get_oo_assert_fee(self: @ContractState) -> u256 {
            let oracle_dispatcher = IPragmaABIDispatcher {
                contract_address: ORACLE_ADDRESS.try_into().unwrap()
            };
            let response = oracle_dispatcher.get_data_median(DataType::SpotEntry('ETH/USD'));
            assert(response.price > 0, 'FETCHING_PRICE_ERROR');
            let mut eth_assertion_fee = dollar_to_wei(ASSERTION_FEE, response.price, response.decimals);
            eth_assertion_fee.into()
        }

    }

    // ---
    #[generate_trait]
    impl InternalTraitImpl of InternalTrait {
        fn assert_thruth_with_defaults(
            self: @ContractState, claim: ByteArray, bond: u256
        ) -> felt252 {
            self
                .oo
                .read()
                .assert_truth(
                    claim,
                    get_caller_address(),
                    get_contract_address(),
                    contract_address_const::<0>(),
                    ASSERTION_LIVENESS,
                    self.bond_token.read(),
                    bond,
                    self.default_identifier.read(),
                    0
                )
        }
    }

    fn compose_claim(outcome: ByteArray, description: ByteArray) -> ByteArray {
        let mut claim: ByteArray = Default::default();
        let p1: ByteArray = "As of assertion timestamp ";
        let p2: ByteArray = ", the described prediction market outcome is: ";
        let p3: ByteArray = ". The market description is: ";
        let mut block_timestamp: ByteArray = Default::default();
        block_timestamp.append_word(get_block_timestamp().into(), 8);
        claim = ByteArrayTrait::concat(@claim, @p1);
        claim = ByteArrayTrait::concat(@claim, @block_timestamp);
        claim = ByteArrayTrait::concat(@claim, @p2);
        claim = ByteArrayTrait::concat(@claim, @outcome);
        claim = ByteArrayTrait::concat(@claim, @p3);
        claim = ByteArrayTrait::concat(@claim, @description);
        claim
    }

    fn dollar_to_wei(usd: u128, price: u128, decimals: u32) -> u128 {
        (usd * pow(10, decimals.into()) * 1000000000000000000) / (price * 100000000)
    }
}

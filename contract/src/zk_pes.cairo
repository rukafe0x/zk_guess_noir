// This contract is for ZK game where a user A think a number, register the commitment in the contract
// and then user B try to guess the number calling the guess_intent function which will store the intent in the contract.
// Once A or B made their intent, user will send the proof to the verifier to check if the opponent guess is correct.
// If guess is correct, then the user will call the send_reward function for give reward to the opponent.
//  --- PRIVATE INPUTS (solo A los conoce) ---
// signal input x;      // número secreto elegido por A
// signal input salt;   // sal aleatoria para el compromiso

//  --- PUBLIC INPUTS (visibles en blockchain) ---
// signal input h;      // compromiso publicado on-chain
// signal input y;      // intento del jugador B
// signal output equal; // resultado (1 si acierta, 0 si no)
use starknet::{ContractAddress};

#[starknet::interface]
pub trait IZKPes<TContractState> {
    // Register the commitment of the number
    fn create_game(
        ref self: TContractState,
        game_id: u256,
        commitment: u256,
        reward: u256,
    );
    // Join the game
    fn join_game(ref self: TContractState, game_id: u256, commitment: u256);
    // Send the intent of the number
    fn write_intent(ref self: TContractState, game_id: u256, intent: u256);
    // Verify intent
    fn verify_intent(ref self: TContractState, game_id: u256, full_proof_with_hints: Span<felt252>);
    // Claim the reward to the winner
    fn claim_reward(ref self: TContractState, game_id: u256);
    // getter for a game properties (one function return all properties)
    fn get_game_properties(self: @TContractState, game_id: u256) -> (ContractAddress, ContractAddress, u256, u256, u256, u256, u64, felt252);
}

#[starknet::interface]
trait IVerifyGroth16ProofBN254<TContractState> {
    fn verify_groth16_proof_bn254(
        self: @TContractState,
        full_proof_with_hints: Span<felt252>,
    ) -> Option<Span<u256>>;
}

#[starknet::contract]
mod ZKPes {
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use super::{IVerifyGroth16ProofBN254Dispatcher, IVerifyGroth16ProofBN254DispatcherTrait};
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, Map,
    };
    use starknet::{ContractAddress, get_caller_address, get_block_info, get_contract_address};
    use core::traits::{TryInto,Into};
    


    #[storage]
    struct Storage {
        games: Map<u256, game_struct>,
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct game_struct {
        player1: ContractAddress,
        player2: ContractAddress,
        commitment1: u256,
        commitment2: u256,
        reward: u256,
        last_intent: u256,
        last_intent_blocknumber: u64,
        status: felt252,
    }

    #[event]
    #[derive(Drop, PartialEq, starknet::Event)]
    pub enum Event {
        Status: Status,
        PublicInputs: PublicInputs,
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct Status {
        #[key]
        pub game_id: u256,
        pub status: felt252,
        pub value: felt252,
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct PublicInputs {
        #[key]
        pub public_input: u256,
    }

    #[abi(embed_v0)]
    impl IZKPes of super::IZKPes<ContractState> {
        fn create_game(
            ref self: ContractState,
            game_id: u256,
            commitment: u256,
            reward: u256,
        ) {
            // Register the commitment
            let mut game=self.games.entry(game_id);
            // if game is not created, create it
            if game.player1.read()==0.try_into().unwrap() {
                game.player1.write(get_caller_address());
                game.commitment1.write(commitment);
            } else {
                panic!("Game id already exists");
            }
            // transfer 1 fri strk from the caller
            let strk_token_dispatcher = ERC20ABIDispatcher {
                contract_address: 0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d.try_into().unwrap() // STRK Contract Address
            };
            // Deposit reward to the game
            game.reward.write(reward); // set reward to 1 fri strk
            strk_token_dispatcher.transferFrom(get_caller_address(), get_contract_address(), game.reward.read());
            // set game status to created
            game.status.write('created');
            // emit event
            self.emit(Status { game_id: game_id, status: game.status.read(), value: get_caller_address().into() });
        }

        fn join_game(ref self: ContractState, game_id: u256, commitment: u256) {
            // Register the commitment
            let mut game=self.games.entry(game_id);
            // if game is not created, create it
            if game.player2.read()==0.try_into().unwrap() {
                game.player2.write(get_caller_address());
                game.commitment2.write(commitment);
            } else {
                panic!("Game is already full");
            }
            // transfer 1 fri strk from the caller
            let strk_token_dispatcher = ERC20ABIDispatcher {
                contract_address: 0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d.try_into().unwrap() // STRK Contract Address
            };
            strk_token_dispatcher.transferFrom(get_caller_address(), get_contract_address(), game.reward.read());
            // set game status to joined    
            game.status.write('p1_turn');
            game.last_intent_blocknumber.write(get_block_info().block_number.into());
            // emit event
            self.emit(Status { game_id: game_id, status: game.status.read(), value: get_caller_address().into() });
        }

        fn write_intent(ref self: ContractState, game_id: u256, intent: u256) {
            // check which player is calling the function
            let mut game=self.games.entry(game_id);
            //check if is p1_turn or p2_turn
            let player_address=get_caller_address();
            if game.status.read()=='p1_turn' {
                if player_address!=game.player1.read() {
                    panic!("You are not player 1");
                }
            } else if game.status.read()=='p2_turn' {
                if player_address!=game.player2.read() {
                    panic!("You are not player 2");
                }
            } else {
                panic!("It's not your turn");
            }
            // Check if blocknumber has advanced 1000 blocks since last intent
            assert(get_block_info().block_number-game.last_intent_blocknumber.read()<=1000, '1000 blocks since last intent');
            // write the intent
            game.last_intent.write(intent);
            game.last_intent_blocknumber.write(get_block_info().block_number.into());
            // change the turn
            if game.status.read()=='p1_turn' {
                game.status.write('p2_verify');
            } else {
                game.status.write('p1_verify');
            }
            // emit event
            self.emit(Status { game_id: game_id, status: game.status.read(), value: intent.try_into().unwrap() });
        }

        fn verify_intent(ref self: ContractState, game_id: u256, full_proof_with_hints: Span<felt252>) {
            // First check if it's your turn
            let player_address=get_caller_address();
            let mut game=self.games.entry(game_id);
            if game.status.read()!='p1_verify' && game.status.read()!='p2_verify' {
                panic!("It's not your turn");
            }
            if game.status.read()=='p1_verify' {
                if player_address!=game.player1.read() {
                    panic!("You are not player 1");
                }
            } else {
                if player_address!=game.player2.read() {
                    panic!("You are not player 2");
                }
            }

            // Check if blocknumber has advanced 1000 blocks since last intent
            assert(get_block_info().block_number-game.last_intent_blocknumber.read()<=1000, '1000 blocks since last intent');

            // verify the proof and get the public inputs
            // calling this external contract function 
            // deployed in 0x0450e153f3eb3ec93d17ffb41cc00a8993d1b1f188773e4e6a228c0332004b88
            // fn verify_groth16_proof_bn254(
            //     self: @ContractState,
            //     full_proof_with_hints: Span<felt252>,
            // ) -> Option<Span<u256>> {
            let verify_groth16_proof_bn254_dispatcher = IVerifyGroth16ProofBN254Dispatcher {
                contract_address: 0x03bf0095806f53a27d89fd105159057f2bdd190432c55e152c517efb4c5d2cd6.try_into().unwrap() // VerifyGroth16ProofBN254 Contract Address
            };
            let public_inputs=verify_groth16_proof_bn254_dispatcher.verify_groth16_proof_bn254(full_proof_with_hints);
            match public_inputs {
                Some(public_inputs) => {
                    // At his point proof is valid
                    // let mut index = 0;
                    // while index < public_inputs.len() {
                    //     self.emit(PublicInputs { public_input: *public_inputs.at(index) });
                    //     index += 1;
                    // }
                    // return;

                    // Verify the intent is correct and is not cheating
                    assert(game.last_intent.read()==*public_inputs.at(2), 'Intent is incorrect');
                    // Verify the commitment is correct and player is not cheating
                    if game.status.read()=='p1_verify' {
                        assert(game.commitment1.read()==*public_inputs.at(1), 'Commitment p1 is incorrect');
                    } else {
                        assert(game.commitment2.read()==*public_inputs.at(1), 'Commitment p2 is incorrect');
                    }                    
                    if (*public_inputs.at(0)==1) {
                        // Opponent guessed correctly
                        // Change status to win_p1 or win_p2
                        if game.status.read()=='p1_verify' {
                            game.status.write('win_p2');
                            // emit event
                            self.emit(Status { game_id: game_id, status: game.status.read(), value: game.player2.read().into() });
                        } else {
                            game.status.write('win_p1');
                            // emit event
                            self.emit(Status { game_id: game_id, status: game.status.read(), value: game.player1.read().into() });
                        }
                    } else {
                        // Incorrect guess, change turn
                        if game.status.read()=='p1_verify' {
                            game.status.write('p1_turn');
                            // emit event
                            self.emit(Status { game_id: game_id, status: game.status.read(), value: game.player1.read().into() });
                        } else {
                            game.status.write('p2_turn');
                            // emit event
                            self.emit(Status { game_id: game_id, status: game.status.read(), value: game.player2.read().into() });
                        }
                    }
                    return;
                },
                None => {
                    panic!("Proof is invalid");
                }
            }
        }

        fn claim_reward(ref self: ContractState, game_id: u256) {
            // Check msg sender is the winner
            // or if blocknumber has advanced 1000 blocks since last intent
            let player_address=get_caller_address();
            let mut game=self.games.entry(game_id);
            if game.status.read()=='win_p1' {
                assert(player_address==game.player1.read(), 'You are not the winner');
            } else if game.status.read()=='win_p2' {
                assert(player_address==game.player2.read(), 'You are not the winner');
            } else if game.status.read()=='p1_turn' {
                assert(get_block_info().block_number-game.last_intent_blocknumber.read()>1000, 'Block not advanced 1000 blocks');
                assert(player_address==game.player2.read(), 'You are not the winner');
            } else if game.status.read()=='p2_turn' {
                assert(get_block_info().block_number-game.last_intent_blocknumber.read()>1000, 'Block not advanced 1000 blocks');
                assert(player_address==game.player1.read(), 'You are not the winner');
            } else {
                panic!("You are not the winner");
            }
            
            //transfer reward to winner
            let reward=game.reward.read();
            let strk_token_dispatcher = ERC20ABIDispatcher {
                contract_address: 0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d.try_into().unwrap() // STRK Contract Address
            };
            strk_token_dispatcher.transfer(player_address, reward);
            // change status to finished
            game.status.write('finished');
            // emit event
            self.emit(Status { game_id: game_id, status: game.status.read(), value: player_address.into() });
        }

        fn get_game_properties(self: @ContractState, game_id: u256) -> (ContractAddress, ContractAddress, u256, u256, u256, u256, u64, felt252) {
            return (self.games.entry(game_id).player1.read(), 
            self.games.entry(game_id).player2.read(), 
            self.games.entry(game_id).commitment1.read(), 
            self.games.entry(game_id).commitment2.read(), 
            self.games.entry(game_id).reward.read(), 
            self.games.entry(game_id).last_intent.read(), 
            self.games.entry(game_id).last_intent_blocknumber.read(), 
            self.games.entry(game_id).status.read());
        }
    }
}

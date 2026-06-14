use alloy_consensus::{SignableTransaction, TxEip1559, TxEnvelope, TxLegacy};
use alloy_dyn_abi::{
    eip712::TypedData, DynSolType, DynSolValue, EventExt, FunctionExt, JsonAbiExt, Specifier,
};
use alloy_eips::eip2718::Encodable2718;
use alloy_eips::eip2930::AccessList;
use alloy_json_abi::{Event, Function, JsonAbi, Param, StateMutability};
use alloy_primitives::{Address, Bytes, TxKind, B256, I256, U256};
use alloy_signer::{Signer, SignerSync};
use alloy_signer_local::PrivateKeySigner;
use godot::builtin::{Array, Dictionary, GString, PackedByteArray, Variant};
use godot::classes::{IRefCounted, ProjectSettings, RefCounted};
use godot::prelude::*;
use num_bigint::{BigInt, BigUint};
use num_traits::{One, Zero};
use rand::thread_rng;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use tiny_keccak::{Hasher, Keccak};

const KEYSTORE_FILE: &str = "account.json";
const STORAGE_DIR: &str = "user://AlephVault.EVM/native_wallet";
const DEFAULT_IMPORTED_PRIVATE_KEY_PASSWORD: &str = "default";

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct AlephVaultEvmNativeWallet {
    base: Base<RefCounted>,
    ready: bool,
    chain_id: i64,
    rpc_url: String,
    accounts: Vec<String>,
    wallet: Option<PrivateKeySigner>,
    abis: HashMap<String, String>,
    contracts: HashMap<String, String>,
}

enum PreparedTx {
    Legacy(TxLegacy),
    Eip1559(TxEip1559),
}

impl PreparedTx {
    fn signature_hash(&self) -> B256 {
        match self {
            Self::Legacy(tx) => tx.signature_hash(),
            Self::Eip1559(tx) => tx.signature_hash(),
        }
    }

    fn into_signed_bytes(self, signature: alloy_primitives::Signature) -> Vec<u8> {
        match self {
            Self::Legacy(tx) => {
                let signed = tx.into_signed(signature);
                let mut out = Vec::with_capacity(signed.network_encoded_length());
                signed.network_encode(&mut out);
                out
            }
            Self::Eip1559(tx) => {
                let envelope = TxEnvelope::Eip1559(tx.into_signed(signature));
                let mut out = Vec::with_capacity(envelope.encode_2718_len());
                envelope.encode_2718(&mut out);
                out
            }
        }
    }
}

#[godot_api]
impl IRefCounted for AlephVaultEvmNativeWallet {
    // Rationale: Godot constructs RefCounted extension objects through this
    // hook, so every cache starts empty until initialize() receives game data.
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            ready: false,
            chain_id: 0,
            rpc_url: String::new(),
            accounts: Vec::new(),
            wallet: None,
            abis: HashMap::new(),
            contracts: HashMap::new(),
        }
    }
}

#[godot_api]
impl AlephVaultEvmNativeWallet {
    #[func]
    // Rationale: initialization exposes only chain state and addresses to
    // GDScript. The signer must already be unlocked and remain inside Rust.
    fn initialize(&mut self) -> Dictionary {
        if !keystore_exists() {
            return failed("no_valid_accounts");
        }
        if self.rpc_url.is_empty() || self.chain_id <= 0 {
            return failed("no_valid_chains");
        }
        if self.wallet.is_none() {
            return failed("not_unlocked");
        }

        self.ready = true;
        success(self.config_json())
    }

    #[func]
    // Rationale: the binding facade exposes chain id as an integer, while raw
    // RPC uses hex quantities; this is the local authoritative chain state.
    fn get_chain_id(&self) -> Dictionary {
        if !self.ready {
            return failed("not_ready");
        }
        success(json!(self.chain_id))
    }

    #[func]
    // Rationale: the native wallet is intentionally bound to exactly one RPC
    // chain from initialize(); this compatibility method fails predictably.
    fn set_chain_id(&mut self, _chain_id: i64, _config_json: GString) -> Dictionary {
        if !self.ready {
            return failed("not_ready");
        }
        failed("not_supported")
    }

    #[func]
    // Rationale: callers need the same account discovery surface on native as
    // on web, but native accounts are derived from configured private keys.
    fn get_accounts(&self) -> Dictionary {
        if !self.ready {
            return failed("not_ready");
        }
        success(json!(self.accounts))
    }

    #[func]
    // Rationale: most JSON-RPC calls should pass through unchanged, but wallet
    // and signing methods must be implemented locally so private keys never
    // leave the native binding.
    fn request(&mut self, method: GString, params_json: GString) -> Dictionary {
        let method = method.to_string();
        if !self.ready && method != "eth_accounts" && method != "eth_requestAccounts" {
            return failed("not_ready");
        }

        let params = match serde_json::from_str::<Value>(&params_json.to_string()) {
            Ok(Value::Array(values)) => Value::Array(values),
            Ok(_) => return failed("invalid_params"),
            Err(_) => return failed("invalid_params"),
        };

        let local = match method.as_str() {
            "eth_accounts" | "eth_requestAccounts" => Some(Ok(json!(self.accounts))),
            "eth_chainId" => Some(Ok(json!(format!("0x{:x}", self.chain_id)))),
            "eth_sign" => Some(self.handle_eth_sign(&params)),
            "personal_sign" => Some(self.handle_personal_sign(&params)),
            "eth_signTypedData" | "eth_signTypedData_v3" | "eth_signTypedData_v4" => {
                Some(self.handle_sign_typed_data(&params))
            }
            "eth_signTransaction" => Some(self.handle_sign_transaction(&params)),
            "eth_sendTransaction" => Some(self.handle_send_transaction(&params)),
            "wallet_addEthereumChain" => Some(self.handle_add_chain(&params)),
            "wallet_switchEthereumChain" => Some(self.handle_switch_chain(&params)),
            _ => None,
        };

        let result = match local {
            Some(result) => result,
            None => {
                if self.rpc_url.is_empty() {
                    return failed("not_ready");
                }
                rpc_request(&self.rpc_url, &method, params)
            }
        };

        match result {
            Ok(value) => success(value),
            Err(error) => error_response(error),
        }
    }

    #[func]
    // Rationale: ABIs are cached by key so contract helpers can operate on a
    // stable Godot-side handle without resending ABI JSON every call.
    fn set_abi(&mut self, key: GString, abi_json: GString) -> Dictionary {
        let key_string = key.to_string();
        if !is_identifier(&key_string) {
            return failed("invalid_key");
        }
        let Ok(abi) = serde_json::from_str::<Value>(&abi_json.to_string()) else {
            return failed("invalid_abi");
        };
        if !matches!(abi, Value::Array(ref entries) if !entries.is_empty()) {
            return failed("invalid_abi");
        }
        self.abis.insert(key_string, abi_json.to_string());
        success(Value::Null)
    }

    #[func]
    // Rationale: exposing ABI retrieval keeps native and web bindings symmetric
    // and lets users inspect or reuse previously registered ABI definitions.
    fn get_abi(&self, key: GString) -> Dictionary {
        match self.abis.get(&key.to_string()) {
            Some(abi) => match serde_json::from_str::<Value>(abi) {
                Ok(value) => success(value),
                Err(_) => failed("invalid_abi"),
            },
            None => failed("not_found"),
        }
    }

    #[func]
    // Rationale: Keccak-256 is a core EVM primitive used for selectors,
    // topics, address checksum calculation, and general dapp utilities.
    fn keccak256(&self, bytes: PackedByteArray) -> Dictionary {
        let input = bytes.to_vec();
        let mut output = [0u8; 32];
        let mut hasher = Keccak::v256();
        hasher.update(&input);
        hasher.finalize(&mut output);
        success_bytes(output.to_vec())
    }

    #[func]
    // Rationale: unit conversion must be available offline and deterministic,
    // independent of the connected RPC node.
    fn from_wei(&self, amount: GString, unit: GString) -> Dictionary {
        convert_from_wei(&amount.to_string(), &unit.to_string())
    }

    #[func]
    // Rationale: native and web callers should use the same decimal-string
    // amount API to avoid precision loss from floating point values.
    fn to_wei(&self, amount: GString, unit: GString) -> Dictionary {
        convert_to_wei(&amount.to_string(), &unit.to_string())
    }

    #[func]
    // Rationale: checksum conversion is local validation/formatting logic and
    // should not depend on a provider.
    fn to_checksum_address(&self, address: GString) -> Dictionary {
        let address = address.to_string();
        let Some(stripped) = normalize_address(&address) else {
            return failed("invalid_address");
        };
        success(json!(checksum_address(&stripped)))
    }

    #[func]
    // Rationale: RPC transaction fields often need canonical hex quantities,
    // while the public API represents large numbers as decimal strings.
    fn decimal_to_hex(&self, decimal: GString) -> Dictionary {
        let decimal = decimal.to_string();
        if !is_decimal_uint(&decimal) {
            return failed("invalid_value");
        }
        let Some(value) = BigUint::parse_bytes(decimal.as_bytes(), 10) else {
            return failed("invalid_value");
        };
        success(json!(format!("0x{}", value.to_str_radix(16))))
    }

    #[func]
    // Rationale: balances and RPC quantities arrive as hex, but the addon API
    // documents large numeric values as decimal strings.
    fn hex_to_decimal(&self, hex: GString) -> Dictionary {
        let hex = hex.to_string();
        if !is_prefixed_hex_quantity(&hex) {
            return failed("invalid_value");
        }
        let Some(value) = BigUint::parse_bytes(hex[2..].as_bytes(), 16) else {
            return failed("invalid_value");
        };
        success(json!(value.to_str_radix(10)))
    }

    #[func]
    // Rationale: ABI and contract helpers need local range checks for unsigned
    // Solidity integer sizes before encoding values.
    fn validate_uint(&self, value: GString, size: i64) -> Dictionary {
        let value = value.to_string();
        if !is_int_size(size) {
            return failed("invalid_size");
        }
        if !is_decimal_uint(&value) {
            return failed("invalid_value");
        }
        let Some(value) = BigUint::parse_bytes(value.as_bytes(), 10) else {
            return failed("invalid_value");
        };
        let max = (BigUint::one() << size as usize) - BigUint::one();
        if value > max {
            return failed("invalid_value");
        }
        success(Value::Null)
    }

    #[func]
    // Rationale: signed Solidity integer validation is separate from unsigned
    // validation because the accepted range is two's-complement sized.
    fn validate_int(&self, value: GString, size: i64) -> Dictionary {
        let value = value.to_string();
        if !is_int_size(size) {
            return failed("invalid_size");
        }
        let Some(value) = BigInt::parse_bytes(value.as_bytes(), 10) else {
            return failed("invalid_value");
        };
        let min = -(BigInt::one() << (size as usize - 1));
        let max = (BigInt::one() << (size as usize - 1)) - BigInt::one();
        if value < min || value > max {
            return failed("invalid_value");
        }
        success(Value::Null)
    }

    #[func]
    // Rationale: address validation is shared by signing, transfers, contract
    // registration, and optional EIP-55 checksum enforcement.
    fn validate_address(&self, value: GString, checksum: bool) -> Dictionary {
        let value = value.to_string();
        let Some(stripped) = normalize_address(&value) else {
            return failed("invalid_value");
        };
        if checksum && checksum_address(&stripped) != ensure_0x(&value) {
            return failed("invalid_value");
        }
        success(Value::Null)
    }

    #[func]
    fn account_exists(&self) -> Dictionary {
        success(json!(keystore_exists()))
    }

    #[func]
    fn account_create(&mut self, password: GString) -> Dictionary {
        if self.wallet.is_some() {
            return failed("invalid_state");
        }
        let password = password.to_string();
        if password.is_empty() {
            return failed("empty_password");
        }
        let storage_dir = storage_dir();
        if keystore_exists() {
            return failed("invalid_state");
        }
        if fs::create_dir_all(&storage_dir).is_err() {
            return failed("os_error");
        }
        let keystore_path = Path::new(&storage_dir).join(KEYSTORE_FILE);
        if keystore_path.exists() && fs::remove_file(&keystore_path).is_err() {
            return failed("os_error");
        }

        let mut rng = thread_rng();
        let Ok((wallet, _uuid)) = PrivateKeySigner::new_keystore(
            &storage_dir,
            &mut rng,
            password.as_bytes(),
            Some(KEYSTORE_FILE),
        ) else {
            return failed("crypto_error");
        };

        self.clear_unlocked_state();
        success(json!(format_address(wallet.address())))
    }

    #[func]
    fn account_destroy(&mut self) -> Dictionary {
        if self.wallet.is_some() {
            return failed("invalid_state");
        }
        let keystore_path = keystore_path();
        if !Path::new(&keystore_path).exists() {
            return failed("invalid_state");
        }
        if fs::remove_file(&keystore_path).is_err() {
            return failed("os_error");
        }
        self.clear_all_state();
        success(Value::Null)
    }

    #[func]
    fn account_backup(&self, target_path: GString) -> Dictionary {
        if self.wallet.is_some() {
            return failed("invalid_state");
        }
        let keystore_path = keystore_path();
        if !Path::new(&keystore_path).exists() {
            return failed("invalid_state");
        }
        if copy_file(&keystore_path, &globalize_path(&target_path.to_string())).is_err() {
            return failed("os_error");
        }
        success(Value::Null)
    }

    #[func]
    fn account_restore(&mut self, source_path: GString) -> Dictionary {
        if self.wallet.is_some() {
            return failed("invalid_state");
        }
        let storage_dir = storage_dir();
        let keystore_path = keystore_path();
        if Path::new(&keystore_path).exists() {
            return failed("invalid_state");
        }
        let source_path = globalize_path(&source_path.to_string());
        if fs::create_dir_all(&storage_dir).is_err() {
            return failed("os_error");
        }

        let Ok(contents) = fs::read_to_string(&source_path) else {
            return failed("invalid_backup");
        };
        match restore_source_kind(&contents) {
            RestoreSourceKind::EncryptedBackup => {
                if copy_file(&source_path, &keystore_path).is_err() {
                    return failed("os_error");
                }
            }
            RestoreSourceKind::PrivateKey(wallet) => {
                let mut rng = thread_rng();
                let Ok((_wallet, _uuid)) = PrivateKeySigner::encrypt_keystore(
                    &storage_dir,
                    &mut rng,
                    wallet.to_bytes().as_slice(),
                    DEFAULT_IMPORTED_PRIVATE_KEY_PASSWORD.as_bytes(),
                    Some(KEYSTORE_FILE),
                ) else {
                    return failed("crypto_error");
                };
            }
            RestoreSourceKind::InvalidPrivateKey => return failed("invalid_private_key"),
            RestoreSourceKind::InvalidBackup => return failed("invalid_backup"),
        }
        self.clear_unlocked_state();
        success(Value::Null)
    }

    #[func]
    fn account_unlock(&mut self, password: GString) -> Dictionary {
        if self.wallet.is_some() {
            return failed("invalid_state");
        }
        let keystore_path = keystore_path();
        if !Path::new(&keystore_path).exists() {
            return failed("invalid_state");
        }
        let Ok(wallet) =
            PrivateKeySigner::decrypt_keystore(&keystore_path, password.to_string().as_bytes())
        else {
            return failed("invalid_password");
        };
        let address = format_address(wallet.address());
        self.wallet = Some(wallet);
        self.accounts = vec![address.clone()];
        self.ready = false;
        success(json!(address))
    }

    #[func]
    fn account_lock(&mut self) -> Dictionary {
        if self.wallet.is_none() {
            return failed("invalid_state");
        }
        self.clear_ready_state();
        success(Value::Null)
    }

    #[func]
    fn account_set_password(&mut self, password: GString) -> Dictionary {
        if self.wallet.is_none() {
            return failed("invalid_state");
        }
        let password = password.to_string();
        if password.is_empty() {
            return failed("empty_password");
        }
        let storage_dir = storage_dir();
        let final_path = Path::new(&storage_dir).join(KEYSTORE_FILE);
        if !final_path.exists() {
            return failed("invalid_state");
        }
        let Some(wallet) = self.wallet.as_ref() else {
            return failed("invalid_state");
        };
        if fs::create_dir_all(&storage_dir).is_err() {
            return failed("os_error");
        }
        let mut rng = thread_rng();
        let new_name = "account-new.json";
        let new_path = Path::new(&storage_dir).join(new_name);
        let backup_path = Path::new(&storage_dir).join("account-old.json");
        if new_path.exists() {
            let _ = fs::remove_file(&new_path);
        }
        if backup_path.exists() {
            let _ = fs::remove_file(&backup_path);
        }
        let Ok((_wallet, _uuid)) = PrivateKeySigner::encrypt_keystore(
            &storage_dir,
            &mut rng,
            wallet.to_bytes().as_slice(),
            password.as_bytes(),
            Some(new_name),
        ) else {
            return failed("crypto_error");
        };
        if fs::rename(&final_path, &backup_path).is_err() {
            return failed("os_error");
        }
        if fs::rename(&new_path, &final_path).is_err() {
            let _ = fs::rename(&backup_path, &final_path);
            return failed("os_error");
        }
        let _ = fs::remove_file(&backup_path);
        success(Value::Null)
    }

    #[func]
    fn account_private_key(&self) -> Dictionary {
        let Some(wallet) = self.wallet.as_ref() else {
            return failed("invalid_state");
        };
        success(json!(format!("0x{}", hex::encode(wallet.to_bytes()))))
    }

    #[func]
    fn set_chain(&mut self, rpc_url: GString) -> Dictionary {
        let rpc_url = rpc_url.to_string();
        if !(rpc_url.starts_with("http://") || rpc_url.starts_with("https://")) {
            return failed("invalid_rpc_url");
        }
        let Ok(chain_value) = rpc_request(&rpc_url, "eth_chainId", json!([])) else {
            return failed("invalid_chain");
        };
        let Some(chain_id) = chain_id_value_to_i64(&chain_value) else {
            return failed("invalid_chain");
        };
        if chain_id <= 0 {
            return failed("invalid_chain");
        }
        self.rpc_url = rpc_url;
        self.chain_id = chain_id;
        success(self.config_json())
    }

    #[func]
    // Rationale: explicit ABI encoding lets callers construct calldata or hash
    // inputs without creating a contract instance.
    fn abi_encode(&self, args_json: GString) -> Dictionary {
        let Ok(args) = serde_json::from_str::<Value>(&args_json.to_string()) else {
            return failed("invalid_args");
        };
        let Some(tokens) = abi_args_to_tokens(&args) else {
            return failed("invalid_args");
        };
        match DynSolValue::Tuple(tokens).abi_encode_sequence() {
            Some(bytes) => success_bytes(bytes),
            None => failed("invalid_args"),
        }
    }

    #[func]
    // Rationale: packed encoding is used by Solidity packed-hash workflows and
    // must match the web helper's explicit-type behavior.
    fn abi_encode_packed(&self, args_json: GString) -> Dictionary {
        let Ok(args) = serde_json::from_str::<Value>(&args_json.to_string()) else {
            return failed("invalid_args");
        };
        let Some(tokens) = abi_args_to_tokens(&args) else {
            return failed("invalid_args");
        };
        let mut bytes = Vec::new();
        for token in tokens {
            bytes.extend(token.abi_encode_packed());
        }
        success_bytes(bytes)
    }

    #[func]
    // Rationale: decoding raw ABI bytes is needed for eth_call results and for
    // callers that manage calldata/result bytes manually.
    fn abi_decode(&self, bytes: PackedByteArray, spec_json: GString) -> Dictionary {
        let Ok(spec) = serde_json::from_str::<Value>(&spec_json.to_string()) else {
            return failed("invalid_spec");
        };
        let Some(types) = abi_spec_to_types(&spec) else {
            return failed("invalid_spec");
        };
        let tuple_type = DynSolType::Tuple(types);
        match tuple_type.abi_decode_sequence(&bytes.to_vec()) {
            Ok(DynSolValue::Tuple(tokens)) => success(Value::Array(
                tokens.into_iter().map(token_to_json).collect(),
            )),
            Ok(_) => failed("invalid_value"),
            Err(_) => failed("invalid_value"),
        }
    }

    #[func]
    // Rationale: contract_create binds an address to a cached ABI key so later
    // contract helpers can resolve ABI entries by address, matching web cache.
    fn contract_create(&mut self, address: GString, abi_key: GString) -> Dictionary {
        let address = address.to_string();
        if !is_non_zero_address(&address) {
            return failed("invalid_address");
        }
        let abi_key = abi_key.to_string();
        if !self.abis.contains_key(&abi_key) {
            return failed("not_found");
        }
        self.contracts.insert(checksum_or_lower(&address), abi_key);
        success(Value::Null)
    }

    #[func]
    // Rationale: contract calls are either eth_call for view/pure functions or
    // locally signed transactions for state-changing functions.
    fn contract_invoke(
        &self,
        address: GString,
        method_json: GString,
        params_json: GString,
        tx_params_json: GString,
    ) -> Dictionary {
        let address = address.to_string();
        let Some(abi) = self.contract_abi(&address) else {
            return failed("invalid_contract");
        };
        let Ok(method) = serde_json::from_str::<Value>(&method_json.to_string()) else {
            return failed("invalid_method");
        };
        let Ok(params) = serde_json::from_str::<Value>(&params_json.to_string()) else {
            return failed("invalid_params");
        };
        let Ok(tx_params) = serde_json::from_str::<Value>(&tx_params_json.to_string()) else {
            return failed("invalid_params");
        };
        let Some(function) = resolve_function(&abi, &method, &params) else {
            return failed("invalid_method");
        };
        let Some(tokens) = values_to_param_tokens(&params, &function.inputs) else {
            return failed("invalid_params");
        };
        let Ok(data) = function.abi_encode_input(&tokens) else {
            return failed("invalid_params");
        };

        if matches!(
            function.state_mutability,
            StateMutability::View | StateMutability::Pure
        ) {
            let call = normalize_tx_json(merge_tx_json(
                &tx_params,
                &address,
                &format!("0x{}", hex::encode(data)),
                None,
            ));
            let block = tx_params
                .get("block")
                .or_else(|| tx_params.get("blockTag"))
                .cloned()
                .unwrap_or_else(|| json!("latest"));
            let response = rpc_request(&self.rpc_url, "eth_call", json!([call, block]));
            return match response {
                Ok(Value::String(hex_result)) => {
                    let Some(bytes) = decode_hex_bytes(&hex_result) else {
                        return failed("invalid_response");
                    };
                    match function.abi_decode_output(&bytes) {
                        Ok(tokens) => {
                            let values: Vec<Value> =
                                tokens.into_iter().map(token_to_json).collect();
                            if values.len() == 1 {
                                success(values.into_iter().next().unwrap())
                            } else {
                                success(Value::Array(values))
                            }
                        }
                        Err(_) => failed("invalid_response"),
                    }
                }
                Ok(other) => success(other),
                Err(error) => error_response(error),
            };
        }

        let tx = merge_tx_json(
            &tx_params,
            &address,
            &format!("0x{}", hex::encode(data)),
            None,
        );
        match self.sign_and_send_tx(&tx) {
            Ok(hash) => success(json!(hash)),
            Err(error) => error_response(error),
        }
    }

    #[func]
    // Rationale: event queries are regular eth_getLogs calls plus local ABI
    // decoding, so native can match web output without provider-side helpers.
    fn contract_get_events(
        &self,
        address: GString,
        event_json: GString,
        topics_json: GString,
        from: GString,
        to: GString,
    ) -> Dictionary {
        let address = address.to_string();
        let Some(abi) = self.contract_abi(&address) else {
            return failed("invalid_contract");
        };
        let Ok(event_value) = serde_json::from_str::<Value>(&event_json.to_string()) else {
            return failed("invalid_event");
        };
        let Some(event) = resolve_event(&abi, &event_value) else {
            return failed("invalid_event");
        };
        let Ok(topics_value) = serde_json::from_str::<Value>(&topics_json.to_string()) else {
            return failed("invalid_topic");
        };
        let Some(topics) = event_filter_topics(&event, &topics_value) else {
            return failed("invalid_topic");
        };
        if !valid_block_range(&from.to_string(), &to.to_string()) {
            return failed("invalid_block_range");
        }
        let filter = json!({
            "address": address,
            "fromBlock": from.to_string(),
            "toBlock": to.to_string(),
            "topics": topics,
        });
        match rpc_request(&self.rpc_url, "eth_getLogs", json!([filter])) {
            Ok(Value::Array(logs)) => {
                let decoded: Vec<Value> = logs
                    .into_iter()
                    .filter_map(|log| decode_event_log(&event, &log))
                    .collect();
                success(Value::Array(decoded))
            }
            Ok(_) => failed("invalid_response"),
            Err(error) => error_response(error),
        }
    }

    #[func]
    // Rationale: receipts already contain logs, so transaction event decoding
    // should be synchronous and use the registered contract ABI cache.
    fn contract_get_tx_events(&self, tx_obj_json: GString, event_json: GString) -> Dictionary {
        let Ok(tx_obj) = serde_json::from_str::<Value>(&tx_obj_json.to_string()) else {
            return failed("invalid_tx");
        };
        let Ok(event_value) = serde_json::from_str::<Value>(&event_json.to_string()) else {
            return failed("invalid_event");
        };
        let Some(logs) = tx_obj.get("logs").and_then(Value::as_array) else {
            return failed("invalid_tx");
        };
        let mut decoded = Vec::new();
        for log in logs {
            let Some(address) = log.get("address").and_then(Value::as_str) else {
                continue;
            };
            let Some(abi) = self.contract_abi(address) else {
                decoded.push(json!({"rawLog": log}));
                continue;
            };
            let events: Vec<Event> = if event_value.is_null() {
                abi.events().cloned().collect()
            } else if let Some(event) = resolve_event(&abi, &event_value) {
                vec![event]
            } else {
                return failed("invalid_event");
            };
            let mut matched = false;
            for event in events {
                if let Some(value) = decode_event_log(&event, log) {
                    decoded.push(value);
                    matched = true;
                    break;
                }
            }
            if !matched {
                decoded.push(json!({"rawLog": log}));
            }
        }
        success(Value::Array(decoded))
    }

    // Rationale: eth_sign signs the raw Keccak digest for compatibility with
    // legacy provider semantics; it is intentionally not personal_sign.
    fn handle_eth_sign(&self, params: &Value) -> Result<Value, Value> {
        let Some(values) = params.as_array() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        if values.len() < 2 {
            return Err(json_rpc_error(-32602, "invalid params"));
        }
        let Some(wallet) = self.wallet_for_value(&values[0]) else {
            return Err(json_rpc_error(4100, "unknown account"));
        };
        let Some(bytes) = value_to_bytes(&values[1]) else {
            return Err(json_rpc_error(-32602, "invalid message"));
        };
        let hash = B256::from(keccak_bytes(&bytes));
        let signature = wallet
            .sign_hash_sync(&hash)
            .map_err(|error| json_rpc_error(-32000, &error.to_string()))?;
        Ok(json!(signature.to_string()))
    }

    // Rationale: personal_sign applies the standard Ethereum message prefix
    // through Alloy's signer trait, matching browser-wallet behavior.
    fn handle_personal_sign(&self, params: &Value) -> Result<Value, Value> {
        let Some(values) = params.as_array() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        if values.len() < 2 {
            return Err(json_rpc_error(-32602, "invalid params"));
        }
        let (message_value, account_value) = if self.wallet_for_value(&values[0]).is_some() {
            (&values[1], &values[0])
        } else {
            (&values[0], &values[1])
        };
        let Some(wallet) = self.wallet_for_value(account_value) else {
            return Err(json_rpc_error(4100, "unknown account"));
        };
        let Some(bytes) = value_to_bytes(message_value) else {
            return Err(json_rpc_error(-32602, "invalid message"));
        };
        let signature = wallet
            .sign_message_sync(&bytes)
            .map_err(|error| json_rpc_error(-32000, &error.to_string()))?;
        Ok(json!(signature.to_string()))
    }

    // Rationale: typed-data variants are wallet-local signing methods; the
    // node should never see typed data or private signing material.
    fn handle_sign_typed_data(&self, params: &Value) -> Result<Value, Value> {
        let Some(values) = params.as_array() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        if values.len() < 2 {
            return Err(json_rpc_error(-32602, "invalid params"));
        }
        let Some(wallet) = self.wallet_for_value(&values[0]) else {
            return Err(json_rpc_error(4100, "unknown account"));
        };
        let typed_value = if values[1].is_string() {
            serde_json::from_str::<Value>(values[1].as_str().unwrap())
                .map_err(|_| json_rpc_error(-32602, "invalid typed data"))?
        } else {
            values[1].clone()
        };
        let typed_data: TypedData = serde_json::from_value(typed_value)
            .map_err(|_| json_rpc_error(-32602, "invalid typed data"))?;
        let signature = wallet
            .sign_dynamic_typed_data_sync(&typed_data)
            .map_err(|error| json_rpc_error(-32000, &error.to_string()))?;
        Ok(json!(signature.to_string()))
    }

    // Rationale: eth_signTransaction returns a raw signed transaction without
    // broadcasting, useful for offline submission or user inspection.
    fn handle_sign_transaction(&self, params: &Value) -> Result<Value, Value> {
        let Some(values) = params.as_array() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        let Some(tx) = values.first() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        self.sign_transaction(tx)
    }

    // Rationale: eth_sendTransaction must be local in native mode; the binding
    // signs and forwards only eth_sendRawTransaction to the node.
    fn handle_send_transaction(&self, params: &Value) -> Result<Value, Value> {
        let Some(values) = params.as_array() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        let Some(tx) = values.first() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        self.sign_and_send_tx(tx).map(Value::String)
    }

    // Rationale: chain addition is a browser-wallet concern; native games must
    // choose their single RPC chain during initialize().
    fn handle_add_chain(&mut self, _params: &Value) -> Result<Value, Value> {
        Err(json_rpc_error(-32004, "not_supported"))
    }

    // Rationale: the native wallet has no external chain picker, so switching
    // chains is unsupported and chain_changed is never emitted.
    fn handle_switch_chain(&mut self, _params: &Value) -> Result<Value, Value> {
        Err(json_rpc_error(-32004, "not_supported"))
    }

    // Rationale: signing methods identify the signer by address, so this maps
    // JSON-RPC address arguments to the one unlocked native wallet.
    fn wallet_for_value(&self, value: &Value) -> Option<&PrivateKeySigner> {
        let address = value.as_str().and_then(parse_address)?;
        self.wallet
            .as_ref()
            .filter(|wallet| wallet.address() == address)
    }

    // Rationale: transaction requests may omit "from"; in that case native
    // mirrors common wallet behavior by using the one unlocked account.
    fn wallet_for_tx(&self, tx: &Value) -> Option<&PrivateKeySigner> {
        if let Some(from) = tx.get("from") {
            self.wallet_for_value(from)
        } else {
            self.wallet.as_ref()
        }
    }

    // Rationale: all transaction signing funnels through one path so nonce,
    // gas, chain id, and typed transaction handling remain consistent.
    fn sign_transaction(&self, tx: &Value) -> Result<Value, Value> {
        let chain_id = tx
            .get("chainId")
            .or_else(|| tx.get("chain_id"))
            .and_then(chain_id_value_to_i64)
            .unwrap_or(self.chain_id);
        let wallet = self
            .wallet_for_tx(tx)
            .ok_or_else(|| json_rpc_error(4100, "unknown account"))?
            .clone()
            .with_chain_id(Some(chain_id as u64));
        let typed = self.prepare_transaction(tx, wallet.address())?;
        let signature = wallet
            .sign_hash_sync(&typed.signature_hash())
            .map_err(|error| json_rpc_error(-32000, &error.to_string()))?;
        let raw = typed.into_signed_bytes(signature);
        Ok(json!(format!("0x{}", hex::encode(raw))))
    }

    // Rationale: broadcasting is deliberately limited to eth_sendRawTransaction
    // after local signing, preserving native-wallet custody.
    fn sign_and_send_tx(&self, tx: &Value) -> Result<String, Value> {
        let raw = self.sign_transaction(tx)?;
        let Some(raw) = raw.as_str() else {
            return Err(json_rpc_error(-32000, "invalid signed transaction"));
        };
        match rpc_request(&self.rpc_url, "eth_sendRawTransaction", json!([raw])) {
            Ok(Value::String(hash)) => Ok(hash),
            Ok(_) => Err(json_rpc_error(-32000, "invalid transaction hash")),
            Err(error) => Err(error),
        }
    }

    // Rationale: this normalizes JSON-RPC tx config into Alloy typed
    // transactions, filling nonce/gas/fees from RPC only when omitted.
    fn prepare_transaction(&self, tx: &Value, signer: Address) -> Result<PreparedTx, Value> {
        let Some(to) = tx.get("to").and_then(Value::as_str).and_then(parse_address) else {
            return Err(json_rpc_error(-32602, "missing to"));
        };
        let data = tx
            .get("data")
            .and_then(Value::as_str)
            .and_then(decode_hex_bytes)
            .unwrap_or_default();
        let value = tx.get("value").and_then(value_to_u256).unwrap_or_default();
        let nonce = match tx.get("nonce").and_then(value_to_u64) {
            Some(value) => value,
            None => {
                let nonce = rpc_request(
                    &self.rpc_url,
                    "eth_getTransactionCount",
                    json!([format_address(signer), "pending"]),
                )?;
                value_to_u64(&nonce).ok_or_else(|| json_rpc_error(-32000, "invalid nonce"))?
            }
        };
        let gas = match tx
            .get("gas")
            .or_else(|| tx.get("gasLimit"))
            .and_then(value_to_u64)
        {
            Some(value) => value,
            None => {
                let estimate = rpc_request(
                    &self.rpc_url,
                    "eth_estimateGas",
                    json!([normalize_tx_json(tx.clone())]),
                )?;
                value_to_u64(&estimate).ok_or_else(|| json_rpc_error(-32000, "invalid gas"))?
            }
        };
        if tx.get("maxFeePerGas").is_some() || tx.get("maxPriorityFeePerGas").is_some() {
            let max_fee_per_gas = tx
                .get("maxFeePerGas")
                .and_then(value_to_u128)
                .ok_or_else(|| json_rpc_error(-32602, "missing maxFeePerGas"))?;
            let max_priority_fee_per_gas =
                match tx.get("maxPriorityFeePerGas").and_then(value_to_u128) {
                    Some(value) => value,
                    None => rpc_request(&self.rpc_url, "eth_maxPriorityFeePerGas", json!([]))
                        .ok()
                        .and_then(|value| value_to_u128(&value))
                        .unwrap_or_default(),
                };
            Ok(PreparedTx::Eip1559(TxEip1559 {
                chain_id: tx
                    .get("chainId")
                    .or_else(|| tx.get("chain_id"))
                    .and_then(chain_id_value_to_i64)
                    .unwrap_or(self.chain_id) as u64,
                nonce,
                gas_limit: gas,
                max_fee_per_gas,
                max_priority_fee_per_gas,
                to: TxKind::Call(to),
                value,
                access_list: AccessList::default(),
                input: Bytes::from(data),
            }))
        } else {
            let gas_price = match tx.get("gasPrice").and_then(value_to_u128) {
                Some(value) => value,
                None => {
                    let gas_price = rpc_request(&self.rpc_url, "eth_gasPrice", json!([]))?;
                    value_to_u128(&gas_price)
                        .ok_or_else(|| json_rpc_error(-32000, "invalid gas price"))?
                }
            };
            Ok(PreparedTx::Legacy(TxLegacy {
                chain_id: Some(
                    tx.get("chainId")
                        .or_else(|| tx.get("chain_id"))
                        .and_then(chain_id_value_to_i64)
                        .unwrap_or(self.chain_id) as u64,
                ),
                nonce,
                gas_price,
                gas_limit: gas,
                to: TxKind::Call(to),
                value,
                input: Bytes::from(data),
            }))
        }
    }

    // Rationale: registered contracts are keyed by normalized address, while
    // ABI JSON is keyed separately to allow reuse across many contracts.
    fn contract_abi(&self, address: &str) -> Option<JsonAbi> {
        let key = self.contracts.get(&checksum_or_lower(address))?;
        let abi_json = self.abis.get(key)?;
        serde_json::from_str::<JsonAbi>(abi_json).ok()
    }

    fn clear_unlocked_state(&mut self) {
        self.ready = false;
        self.accounts.clear();
        self.wallet = None;
    }

    fn clear_ready_state(&mut self) {
        self.ready = false;
        self.accounts.clear();
        self.wallet = None;
    }

    fn clear_all_state(&mut self) {
        self.ready = false;
        self.chain_id = 0;
        self.rpc_url.clear();
        self.accounts.clear();
        self.wallet = None;
    }

    fn config_json(&self) -> Value {
        json!({
            "chain_id": self.chain_id,
            "rpc_url": self.rpc_url,
            "accounts": self.accounts,
        })
    }
}

fn storage_dir() -> String {
    globalize_path(STORAGE_DIR)
}

fn keystore_path() -> String {
    Path::new(&storage_dir())
        .join(KEYSTORE_FILE)
        .to_string_lossy()
        .to_string()
}

fn keystore_exists() -> bool {
    Path::new(&keystore_path()).exists()
}

fn globalize_path(path: &str) -> String {
    let path = GString::from(path);
    ProjectSettings::singleton()
        .globalize_path(&path)
        .to_string()
}

enum RestoreSourceKind {
    EncryptedBackup,
    PrivateKey(PrivateKeySigner),
    InvalidPrivateKey,
    InvalidBackup,
}

fn restore_source_kind(contents: &str) -> RestoreSourceKind {
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        return RestoreSourceKind::InvalidBackup;
    }

    match serde_json::from_str::<Value>(trimmed) {
        Ok(Value::Object(object)) => {
            if let Some(value) = object
                .get("private_key")
                .or_else(|| object.get("privateKey"))
            {
                return match value.as_str().and_then(private_key_signer_from_hex) {
                    Some(wallet) => RestoreSourceKind::PrivateKey(wallet),
                    None => RestoreSourceKind::InvalidPrivateKey,
                };
            }
            RestoreSourceKind::EncryptedBackup
        }
        Ok(_) => RestoreSourceKind::InvalidBackup,
        Err(_) if trimmed.starts_with("0x") => match private_key_signer_from_hex(trimmed) {
            Some(wallet) => RestoreSourceKind::PrivateKey(wallet),
            None => RestoreSourceKind::InvalidPrivateKey,
        },
        Err(_) => RestoreSourceKind::InvalidBackup,
    }
}

fn private_key_signer_from_hex(value: &str) -> Option<PrivateKeySigner> {
    if !value.starts_with("0x") {
        return None;
    }
    let bytes = decode_hex_bytes(value)?;
    if bytes.len() != 32 {
        return None;
    }
    Some(PrivateKeySigner::from_bytes(&B256::from_slice(&bytes)).ok()?)
}

fn copy_file(source: &str, target: &str) -> Result<(), ()> {
    if let Some(parent) = PathBuf::from(target).parent() {
        fs::create_dir_all(parent).map_err(|_| ())?;
    }
    fs::copy(source, target).map_err(|_| ())?;
    Ok(())
}

// Rationale: non-wallet JSON-RPC calls are intentionally thin pass-throughs so
// the native binding follows node behavior for standard Ethereum methods.
fn rpc_request(rpc_url: &str, method: &str, params: Value) -> Result<Value, Value> {
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });

    let response = ureq::post(rpc_url)
        .set("content-type", "application/json")
        .send_json(body)
        .map_err(|error| json!({"code": -32000, "message": error.to_string()}))?;

    let body: Value = response
        .into_json()
        .map_err(|error| json!({"code": -32700, "message": error.to_string()}))?;
    if let Some(error) = body.get("error") {
        return Err(error.clone());
    }
    Ok(body.get("result").cloned().unwrap_or(Value::Null))
}

// Rationale: locally handled wallet methods should return provider-like error
// objects instead of addon-specific string errors.
fn json_rpc_error(code: i64, message: &str) -> Value {
    json!({"code": code, "message": message})
}

// Rationale: parsed addresses are used for signing and tx construction, where
// accepting zero or malformed addresses would create invalid transactions.
fn parse_address(address: &str) -> Option<Address> {
    let bytes = decode_hex_bytes(address)?;
    if bytes.len() != 20 || bytes.iter().all(|byte| *byte == 0) {
        return None;
    }
    Some(Address::from_slice(&bytes))
}

// Rationale: public account/address output should be stable and EIP-55
// checksummed across native and web bindings.
fn format_address(address: Address) -> String {
    checksum_address(&hex::encode(address.as_slice()))
}

// Rationale: contract cache lookups need a normalized key even if callers pass
// mixed-case or non-checksummed address strings.
fn checksum_or_lower(address: &str) -> String {
    normalize_address(address)
        .map(|address| checksum_address(&address))
        .unwrap_or_else(|| address.to_ascii_lowercase())
}

// Rationale: signing and ABI helpers accept either 0x hex bytes or plain UTF-8
// strings, matching common provider conventions.
fn value_to_bytes(value: &Value) -> Option<Vec<u8>> {
    match value {
        Value::String(value) if value.starts_with("0x") => decode_hex_bytes(value),
        Value::String(value) => Some(value.as_bytes().to_vec()),
        _ => None,
    }
}

// Rationale: one strict hex decoder prevents each caller from reimplementing
// prefix, even-length, and hex-character validation.
fn decode_hex_bytes(hex: &str) -> Option<Vec<u8>> {
    let stripped = hex.strip_prefix("0x").unwrap_or(hex);
    if stripped.len() % 2 != 0 || !stripped.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    hex::decode(stripped).ok()
}

// Rationale: chain and block quantities must reject leading-zero/noncanonical
// forms according to JSON-RPC quantity rules.
fn hex_quantity_to_i64(hex: &str) -> Option<i64> {
    if !is_prefixed_hex_quantity(hex) {
        return None;
    }
    i64::from_str_radix(&hex[2..], 16).ok()
}

// Rationale: addon config is authored by games, so accepting int, decimal
// string, and hex quantity reduces friction while normalizing internally.
fn chain_id_value_to_i64(value: &Value) -> Option<i64> {
    match value {
        Value::Number(value) => value.as_i64(),
        Value::String(value) if value.starts_with("0x") => hex_quantity_to_i64(value),
        Value::String(value) => value.parse::<i64>().ok(),
        _ => None,
    }
}

// Rationale: tx and ABI numeric fields can arrive as JSON numbers, decimal
// strings, or RPC hex quantities, but Alloy needs U256 for EVM word values.
fn value_to_u256(value: &Value) -> Option<U256> {
    match value {
        Value::String(value) if value.starts_with("0x") => {
            U256::from_str_radix(&value[2..], 16).ok()
        }
        Value::String(value) => U256::from_str_radix(value, 10).ok(),
        Value::Number(value) => value.as_u64().map(U256::from),
        _ => None,
    }
}

// Rationale: nonce and gas limit fields are consensus-bounded u64 values, so
// conversion must reject values that do not fit instead of truncating them.
fn value_to_u64(value: &Value) -> Option<u64> {
    let value = value_to_u256(value)?;
    value.try_into().ok()
}

// Rationale: fee fields are represented by Alloy consensus structs as u128,
// so conversion must be explicit and checked at the JSON boundary.
fn value_to_u128(value: &Value) -> Option<u128> {
    let value = value_to_u256(value)?;
    value.try_into().ok()
}

// Rationale: ABI signed integer inputs accept the same decimal/hex/number
// shapes as unsigned values while preserving sign for int<M> types.
fn value_to_i256(value: &Value) -> Option<I256> {
    match value {
        Value::String(value) if value.starts_with("0x") => U256::from_str_radix(&value[2..], 16)
            .ok()
            .map(I256::from_raw),
        Value::String(value) => I256::from_dec_str(value).ok(),
        Value::Number(value) => value
            .as_i64()
            .and_then(|value| I256::from_dec_str(&value.to_string()).ok()),
        _ => None,
    }
}

// Rationale: Godot cannot safely represent large EVM integers as native ints,
// so decoded integer output is always a decimal string.
fn u256_to_json(value: U256) -> Value {
    Value::String(value.to_string())
}

// Rationale: several helpers need raw Keccak bytes rather than a Godot
// response dictionary, so this is the internal primitive.
fn keccak_bytes(bytes: &[u8]) -> [u8; 32] {
    let mut output = [0u8; 32];
    let mut hasher = Keccak::v256();
    hasher.update(bytes);
    hasher.finalize(&mut output);
    output
}

// Rationale: contract invocation must set authoritative to/data/value fields
// while preserving caller-supplied tx config such as gas, fees, nonce, from.
fn merge_tx_json(tx_params: &Value, to: &str, data: &str, value: Option<&str>) -> Value {
    let mut tx = tx_params.as_object().cloned().unwrap_or_default();
    tx.insert("to".to_owned(), Value::String(to.to_owned()));
    tx.insert("data".to_owned(), Value::String(data.to_owned()));
    if let Some(value) = value {
        tx.insert("value".to_owned(), Value::String(value.to_owned()));
    }
    Value::Object(tx)
}

// Rationale: Godot callers may use compatibility aliases, but JSON-RPC calls
// should receive canonical transaction field names.
fn normalize_tx_json(tx: Value) -> Value {
    let Value::Object(mut tx) = tx else {
        return tx;
    };
    if !tx.contains_key("gas") {
        if let Some(value) = tx.get("gasLimit").cloned() {
            tx.insert("gas".to_owned(), value);
        }
    }
    if !tx.contains_key("chainId") {
        if let Some(value) = tx.get("chain_id").cloned() {
            tx.insert("chainId".to_owned(), value);
        }
    }
    tx.remove("gasLimit");
    tx.remove("chain_id");
    Value::Object(tx)
}

// Rationale: free-form ABI helpers accept either explicit {type,value} entries
// or inferred plain values, matching the web helper contract.
fn abi_args_to_tokens(args: &Value) -> Option<Vec<DynSolValue>> {
    let args = args.as_array()?;
    let mut tokens = Vec::new();
    for arg in args {
        if let Some(object) = arg.as_object() {
            if let (Some(type_value), Some(value)) = (object.get("type"), object.get("value")) {
                let param_type = parse_param_type(type_value.as_str()?)?;
                tokens.push(value_to_token(value, &param_type)?);
                continue;
            }
        }
        tokens.push(infer_token(arg)?);
    }
    Some(tokens)
}

// Rationale: ABI decoding takes only type specs, so this extracts Alloy
// DynSolType values from strings or ABI-like dictionaries.
fn abi_spec_to_types(spec: &Value) -> Option<Vec<DynSolType>> {
    let spec = spec.as_array()?;
    spec.iter().map(abi_spec_item_to_type).collect()
}

// Rationale: each decode spec item supports the same string-or-dictionary
// shapes documented for the Godot facade.
fn abi_spec_item_to_type(spec: &Value) -> Option<DynSolType> {
    if let Some(type_name) = spec.as_str() {
        return parse_param_type(type_name);
    }
    serde_json::from_value::<Param>(spec.clone())
        .ok()?
        .resolve()
        .ok()
}

// Rationale: Alloy's ABI reader is the source of truth for Solidity type
// syntax instead of maintaining a partial parser.
fn parse_param_type(type_name: &str) -> Option<DynSolType> {
    DynSolType::parse(type_name).ok()
}

// Rationale: contract calls already know ABI input types, so values should be
// encoded against those exact types rather than inferred.
fn values_to_param_tokens(values: &Value, params: &[Param]) -> Option<Vec<DynSolValue>> {
    let values = values.as_array()?;
    if values.len() != params.len() {
        return None;
    }
    values
        .iter()
        .zip(params)
        .map(|(value, param)| value_to_token(value, &param.resolve().ok()?))
        .collect()
}

// Rationale: this is the typed conversion boundary from Godot/JSON values into
// Alloy ABI values for contract calls and explicit ABI encoding.
fn value_to_token(value: &Value, kind: &DynSolType) -> Option<DynSolValue> {
    match kind {
        DynSolType::Address => Some(DynSolValue::Address(
            value.as_str().and_then(parse_address)?,
        )),
        DynSolType::Bytes => Some(DynSolValue::Bytes(value_to_bytes(value)?)),
        DynSolType::FixedBytes(size) => {
            let bytes = value_to_bytes(value)?;
            if bytes.len() == *size {
                let mut word = [0u8; 32];
                word[..bytes.len()].copy_from_slice(&bytes);
                Some(DynSolValue::FixedBytes(B256::from(word), *size))
            } else {
                None
            }
        }
        DynSolType::Int(size) => Some(DynSolValue::Int(value_to_i256(value)?, *size)),
        DynSolType::Uint(size) => Some(DynSolValue::Uint(value_to_u256(value)?, *size)),
        DynSolType::Bool => Some(DynSolValue::Bool(value.as_bool()?)),
        DynSolType::String => Some(DynSolValue::String(value.as_str()?.to_owned())),
        DynSolType::Array(inner) => {
            let values = value.as_array()?;
            values
                .iter()
                .map(|value| value_to_token(value, inner))
                .collect::<Option<Vec<_>>>()
                .map(DynSolValue::Array)
        }
        DynSolType::FixedArray(inner, size) => {
            let values = value.as_array()?;
            if values.len() != *size {
                return None;
            }
            values
                .iter()
                .map(|value| value_to_token(value, inner))
                .collect::<Option<Vec<_>>>()
                .map(DynSolValue::FixedArray)
        }
        DynSolType::Tuple(types) => {
            let values = value.as_array()?;
            if values.len() != types.len() {
                return None;
            }
            values
                .iter()
                .zip(types)
                .map(|(value, kind)| value_to_token(value, kind))
                .collect::<Option<Vec<_>>>()
                .map(DynSolValue::Tuple)
        }
        DynSolType::Function | DynSolType::CustomStruct { .. } => None,
    }
}

// Rationale: untyped ABI encoding exists for convenience; inference is kept
// intentionally close to the web helper, where 0x strings infer as bytes.
fn infer_token(value: &Value) -> Option<DynSolValue> {
    match value {
        Value::Bool(value) => Some(DynSolValue::Bool(*value)),
        Value::String(value) if value.starts_with("0x") => {
            decode_hex_bytes(value).map(DynSolValue::Bytes)
        }
        Value::String(value) if is_decimal_uint(value) => U256::from_str_radix(value, 10)
            .ok()
            .map(|value| DynSolValue::Uint(value, 256)),
        Value::String(value) => Some(DynSolValue::String(value.clone())),
        Value::Number(value) => value
            .as_u64()
            .map(|value| DynSolValue::Uint(U256::from(value), 256)),
        Value::Array(values) => json_array_to_bytes(values).map(DynSolValue::Bytes),
        _ => None,
    }
}

// Rationale: JSON.stringify(PackedByteArray) reaches bindings as an array of
// byte integers, so implicit array ABI args are treated as bytes in both web
// and native. Solidity arrays should be passed with an explicit array type.
fn json_array_to_bytes(values: &[Value]) -> Option<Vec<u8>> {
    values
        .iter()
        .map(|value| value.as_u64().and_then(|value| u8::try_from(value).ok()))
        .collect()
}

// Rationale: decoded ABI values must cross the Godot boundary as JSON-friendly
// variants with large integers preserved as strings.
fn token_to_json(token: DynSolValue) -> Value {
    match token {
        DynSolValue::Address(value) => Value::String(format_address(value)),
        DynSolValue::FixedBytes(value, size) => {
            Value::String(format!("0x{}", hex::encode(&value.as_slice()[..size])))
        }
        DynSolValue::Bytes(value) => Value::String(format!("0x{}", hex::encode(value))),
        DynSolValue::Int(value, _) => Value::String(value.to_string()),
        DynSolValue::Uint(value, _) => u256_to_json(value),
        DynSolValue::Bool(value) => Value::Bool(value),
        DynSolValue::String(value) => Value::String(value),
        DynSolValue::FixedArray(values)
        | DynSolValue::Array(values)
        | DynSolValue::Tuple(values) => {
            Value::Array(values.into_iter().map(token_to_json).collect())
        }
        DynSolValue::Function(value) => Value::String(format!("0x{}", hex::encode(value))),
        DynSolValue::CustomStruct { tuple, .. } => {
            Value::Array(tuple.into_iter().map(token_to_json).collect())
        }
    }
}

// Rationale: method selectors can be a name or full ABI entry; overloads by
// name are resolved by arity to match the existing web helper behavior.
fn resolve_function(abi: &JsonAbi, method: &Value, params: &Value) -> Option<Function> {
    if let Some(name) = method.as_str() {
        let arity = params.as_array().map(Vec::len).unwrap_or_default();
        return abi
            .function(name)?
            .iter()
            .find(|function| function.inputs.len() == arity)
            .cloned();
    }
    serde_json::from_value::<Function>(method.clone()).ok()
}

// Rationale: event selectors follow the same name-or-ABI-entry convention as
// contract methods, with the first named overload matching web behavior.
fn resolve_event(abi: &JsonAbi, event: &Value) -> Option<Event> {
    if let Some(name) = event.as_str() {
        return abi.event(name)?.first().cloned();
    }
    serde_json::from_value::<Event>(event.clone()).ok()
}

// Rationale: event topic filtering accepts either raw topic slots or a map of
// indexed argument names, then produces an eth_getLogs topic array.
fn event_filter_topics(event: &Event, topics: &Value) -> Option<Vec<Value>> {
    let mut output = if event.anonymous {
        Vec::new()
    } else {
        vec![Value::String(format!("{:#x}", event.selector()))]
    };
    if topics.is_null() {
        return Some(output);
    }
    if let Some(values) = topics.as_array() {
        if values.len() > 3 {
            return None;
        }
        for value in values {
            if value.is_null() {
                output.push(Value::Null);
                continue;
            }
            let topic = value.as_str()?;
            let bytes = decode_hex_bytes(topic)?;
            if bytes.len() != 32 {
                return None;
            }
            output.push(Value::String(topic.to_owned()));
        }
        return Some(output);
    }
    if let Some(object) = topics.as_object() {
        for name in object.keys() {
            if !event
                .inputs
                .iter()
                .any(|input| input.indexed && input.name == *name)
            {
                return None;
            }
        }
        for input in event.inputs.iter().filter(|input| input.indexed) {
            if let Some(value) = object.get(&input.name) {
                let kind = input.resolve().ok()?;
                let token = value_to_token(value, &kind)?;
                let encoded = DynSolValue::Tuple(vec![token]).abi_encode_sequence()?;
                let topic = if kind.is_dynamic() {
                    format!("0x{}", hex::encode(keccak_bytes(&encoded)))
                } else {
                    format!("0x{}", hex::encode(encoded))
                };
                output.push(Value::String(topic));
            }
        }
        return Some(output);
    }
    None
}

// Rationale: logs are decoded locally so native returns the same {rawLog,name,
// args} shape as the web helper without needing JavaScript contracts.
fn decode_event_log(event: &Event, log: &Value) -> Option<Value> {
    let topics: Vec<B256> = log
        .get("topics")?
        .as_array()?
        .iter()
        .map(|topic| {
            let bytes = decode_hex_bytes(topic.as_str()?)?;
            if bytes.len() != 32 {
                return None;
            }
            Some(B256::from_slice(&bytes))
        })
        .collect::<Option<Vec<_>>>()?;
    if !event.anonymous && topics.first().copied()? != event.selector() {
        return None;
    }
    let data = decode_hex_bytes(log.get("data")?.as_str()?)?;
    let decoded = event.decode_log_parts(topics, &data).ok()?;
    let mut args = serde_json::Map::new();
    let mut indexed_values = decoded.indexed.into_iter();
    let mut body_values = decoded.body.into_iter();
    for (index, param) in event.inputs.iter().enumerate() {
        let name = if param.name.is_empty() {
            index.to_string()
        } else {
            param.name.clone()
        };
        let value = if param.indexed {
            indexed_values.next()?
        } else {
            body_values.next()?
        };
        args.insert(name, token_to_json(value));
    }
    Some(json!({
        "name": event.name,
        "args": args,
        "rawLog": log,
    }))
}

// Rationale: invalid numeric block ranges are caller errors and should be
// rejected before sending eth_getLogs.
fn valid_block_range(from: &str, to: &str) -> bool {
    if !(is_named_block_tag(from) || is_prefixed_hex_quantity(from)) {
        return false;
    }
    if !(is_named_block_tag(to) || is_prefixed_hex_quantity(to)) {
        return false;
    }
    if is_prefixed_hex_quantity(from) && is_prefixed_hex_quantity(to) {
        return hex_quantity_to_i64(from) <= hex_quantity_to_i64(to);
    }
    true
}

// Rationale: fromWei is deterministic decimal arithmetic and does not require
// a node or wallet.
fn convert_from_wei(amount: &str, unit: &str) -> Dictionary {
    if !is_decimal_uint(amount) {
        return failed("invalid_amount");
    }
    let Some(decimals) = unit_decimals(unit) else {
        return failed("invalid_unit");
    };
    let Some(value) = BigUint::parse_bytes(amount.as_bytes(), 10) else {
        return failed("invalid_amount");
    };
    success(json!(format_units(value, decimals)))
}

// Rationale: toWei must preserve decimal precision by operating on strings
// instead of floats.
fn convert_to_wei(amount: &str, unit: &str) -> Dictionary {
    let Some(decimals) = unit_decimals(unit) else {
        return failed("invalid_unit");
    };
    let Some(value) = parse_units(amount, decimals) else {
        return failed("invalid_amount");
    };
    success(json!(value.to_str_radix(10)))
}

// Rationale: supported units are centralized so conversion validation and
// scaling stay consistent in both directions.
fn unit_decimals(unit: &str) -> Option<usize> {
    match unit {
        "wei" => Some(0),
        "kwei" | "babbage" => Some(3),
        "mwei" | "lovelace" => Some(6),
        "gwei" | "shannon" => Some(9),
        "szabo" => Some(12),
        "finney" => Some(15),
        "ether" | "eth" => Some(18),
        _ => None,
    }
}

// Rationale: decimal user input needs exact fixed-point parsing into an integer
// wei amount with no rounding.
fn parse_units(amount: &str, decimals: usize) -> Option<BigUint> {
    if amount.is_empty() || amount.starts_with('-') {
        return None;
    }
    let parts: Vec<&str> = amount.split('.').collect();
    if parts.len() > 2 || parts[0].is_empty() {
        return None;
    }
    if !parts[0].chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let fractional = if parts.len() == 2 { parts[1] } else { "" };
    if fractional.len() > decimals || !fractional.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let mut digits = parts[0].to_owned();
    digits.push_str(fractional);
    digits.push_str(&"0".repeat(decimals - fractional.len()));
    BigUint::parse_bytes(digits.as_bytes(), 10)
}

// Rationale: integer wei amounts should format to the shortest exact decimal
// representation for display or further string processing.
fn format_units(value: BigUint, decimals: usize) -> String {
    if decimals == 0 {
        return value.to_str_radix(10);
    }
    let scale = BigUint::from(10u32).pow(decimals as u32);
    let integer = &value / &scale;
    let fractional = &value % &scale;
    if fractional.is_zero() {
        return integer.to_str_radix(10);
    }
    let mut fractional_string = fractional.to_str_radix(10);
    while fractional_string.len() < decimals {
        fractional_string.insert(0, '0');
    }
    while fractional_string.ends_with('0') {
        fractional_string.pop();
    }
    format!("{}.{}", integer.to_str_radix(10), fractional_string)
}

// Rationale: EIP-55 checksum casing is computed locally from lowercase address
// bytes using Keccak.
fn checksum_address(stripped: &str) -> String {
    let lower = stripped.to_ascii_lowercase();
    let hash = keccak_hex(lower.as_bytes());
    let mut output = String::from("0x");
    for (i, c) in lower.chars().enumerate() {
        let nibble = u8::from_str_radix(&hash[i..i + 1], 16).unwrap_or(0);
        if c.is_ascii_alphabetic() && nibble >= 8 {
            output.push(c.to_ascii_uppercase());
        } else {
            output.push(c);
        }
    }
    output
}

// Rationale: checksum generation needs a hex-form Keccak digest, distinct from
// the byte-array helper exposed to Godot.
fn keccak_hex(bytes: &[u8]) -> String {
    let mut output = [0u8; 32];
    let mut hasher = Keccak::v256();
    hasher.update(bytes);
    hasher.finalize(&mut output);
    hex::encode(output)
}

// Rationale: many validators need the same optional-0x stripping and 40-hex
// digit check before further address handling.
fn normalize_address(address: &str) -> Option<String> {
    let stripped = address.strip_prefix("0x").unwrap_or(address);
    if stripped.len() != 40 || !stripped.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(stripped.to_owned())
}

// Rationale: transfers and contract registration reject the zero address even
// though it is syntactically valid hex.
fn is_non_zero_address(address: &str) -> bool {
    normalize_address(address)
        .map(|stripped| stripped.chars().any(|c| c != '0'))
        .unwrap_or(false)
}

// Rationale: checksum validation compares against a 0x-prefixed canonical
// string regardless of how the caller supplied the address.
fn ensure_0x(address: &str) -> String {
    if address.starts_with("0x") {
        address.to_owned()
    } else {
        format!("0x{address}")
    }
}

// Rationale: ABI cache keys are constrained to simple identifiers to avoid
// confusing or path-like keys crossing language boundaries.
fn is_identifier(key: &str) -> bool {
    !key.is_empty() && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

// Rationale: decimal unsigned values are represented as strings and must be
// validated before bigint parsing.
fn is_decimal_uint(value: &str) -> bool {
    !value.is_empty() && value.chars().all(|c| c.is_ascii_digit())
}

// Rationale: Solidity int/uint sizes are limited to multiples of 8 through 256
// bits.
fn is_int_size(size: i64) -> bool {
    size >= 8 && size <= 256 && size % 8 == 0
}

// Rationale: JSON-RPC quantities differ from arbitrary hex bytes by requiring
// 0x prefix, at least one digit, and no leading zeroes except 0x0.
fn is_prefixed_hex_quantity(hex: &str) -> bool {
    hex.starts_with("0x")
        && hex.len() > 2
        && !hex[2..].contains("0x")
        && (hex.len() == 3 || !hex[2..].starts_with('0'))
        && hex[2..].chars().all(|c| c.is_ascii_hexdigit())
}

// Rationale: block tags can be named values as well as numeric quantities in
// Ethereum JSON-RPC.
fn is_named_block_tag(tag: &str) -> bool {
    matches!(
        tag,
        "earliest" | "latest" | "pending" | "safe" | "finalized"
    )
}

// Rationale: every Godot-facing method returns the addon-standard success
// dictionary shape.
fn success(value: Value) -> Dictionary {
    let mut dictionary = Dictionary::new();
    dictionary.set("ok", true);
    dictionary.set("value", json_to_variant(value));
    dictionary
}

// Rationale: byte-returning helpers should produce PackedByteArray directly
// instead of hex strings where the facade documents bytes.
fn success_bytes(bytes: Vec<u8>) -> Dictionary {
    let mut packed = PackedByteArray::new();
    for byte in bytes {
        packed.push(byte);
    }
    let mut dictionary = Dictionary::new();
    dictionary.set("ok", true);
    dictionary.set("value", packed);
    dictionary
}

// Rationale: addon validation failures use short string codes that match the
// documented GDScript facade.
fn failed(error: &str) -> Dictionary {
    let mut dictionary = Dictionary::new();
    dictionary.set("ok", false);
    dictionary.set("error", error);
    dictionary
}

// Rationale: JSON-RPC/provider failures can be structured objects, so errors
// must preserve arbitrary JSON-compatible values.
fn error_response(error: Value) -> Dictionary {
    let mut dictionary = Dictionary::new();
    dictionary.set("ok", false);
    dictionary.set("error", json_to_variant(error));
    dictionary
}

// Rationale: Rust JSON values must be converted into Godot Variants before
// crossing the GDExtension boundary.
fn json_to_variant(value: Value) -> Variant {
    match value {
        Value::Null => Variant::nil(),
        Value::Bool(value) => value.to_variant(),
        Value::Number(value) => {
            if let Some(value) = value.as_i64() {
                value.to_variant()
            } else if let Some(value) = value.as_f64() {
                value.to_variant()
            } else {
                value.to_string().to_variant()
            }
        }
        Value::String(value) => value.to_variant(),
        Value::Array(values) => {
            let mut array = Array::new();
            for value in values {
                array.push(&json_to_variant(value));
            }
            array.to_variant()
        }
        Value::Object(values) => {
            let mut dictionary = Dictionary::new();
            for (key, value) in values {
                dictionary.set(key, json_to_variant(value));
            }
            dictionary.to_variant()
        }
    }
}

struct AlephVaultEvmExtension;

#[gdextension]
unsafe impl ExtensionLibrary for AlephVaultEvmExtension {}

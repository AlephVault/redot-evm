use ethers_core::abi::{
    encode, Abi, Event, Function, Param, ParamType, RawLog, StateMutability, Token,
};
use ethers_core::types::transaction::eip2718::TypedTransaction;
use ethers_core::types::transaction::eip712::TypedData;
use ethers_core::types::{transaction::eip1559::Eip1559TransactionRequest, Address, Bytes, H256};
use ethers_core::types::{NameOrAddress, TransactionRequest, U256, U64};
use ethers_signers::{LocalWallet, Signer};
use futures::executor::block_on;
use godot::builtin::{Array, Dictionary, GString, PackedByteArray, Variant};
use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;
use num_bigint::{BigInt, BigUint};
use num_traits::{One, Zero};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::str::FromStr;
use tiny_keccak::{Hasher, Keccak};

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct AlephVaultEvmNativeWallet {
    base: Base<RefCounted>,
    ready: bool,
    chain_id: i64,
    rpc_url: String,
    accounts: Vec<String>,
    wallets: HashMap<Address, LocalWallet>,
    abis: HashMap<String, String>,
    contracts: HashMap<String, String>,
    chains: HashMap<i64, Value>,
}

#[godot_api]
impl IRefCounted for AlephVaultEvmNativeWallet {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            ready: false,
            chain_id: 0,
            rpc_url: String::new(),
            accounts: Vec::new(),
            wallets: HashMap::new(),
            abis: HashMap::new(),
            contracts: HashMap::new(),
            chains: HashMap::new(),
        }
    }
}

#[godot_api]
impl AlephVaultEvmNativeWallet {
    #[func]
    fn initialize(&mut self, config_json: GString) -> Dictionary {
        let Ok(config) = serde_json::from_str::<Value>(&config_json.to_string()) else {
            return failed("invalid_config");
        };

        let chains = config
            .get("chains")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if chains.is_empty() {
            return failed("no_valid_chains");
        }

        let selected_chain_id = config
            .get("chain_id")
            .or_else(|| config.get("chainId"))
            .and_then(chain_id_value_to_i64)
            .or_else(|| {
                chains
                    .first()
                    .and_then(|chain| chain.get("id"))
                    .or_else(|| chains.first().and_then(|chain| chain.get("chain_id")))
                    .or_else(|| chains.first().and_then(|chain| chain.get("chainId")))
                    .and_then(chain_id_value_to_i64)
            });

        let Some(chain_id) = selected_chain_id else {
            return failed("no_valid_chains");
        };

        let Some(chain) = chains
            .iter()
            .find(|chain| {
                chain
                    .get("id")
                    .or_else(|| chain.get("chain_id"))
                    .or_else(|| chain.get("chainId"))
                    .and_then(chain_id_value_to_i64)
                    == Some(chain_id)
            })
            .or_else(|| chains.first())
        else {
            return failed("no_valid_chains");
        };

        let Some(rpc_url) = chain
            .get("rpc_url")
            .or_else(|| chain.get("rpcUrl"))
            .and_then(Value::as_str)
        else {
            return failed("no_valid_chains");
        };

        let (accounts, wallets) = collect_accounts(&config);
        if accounts.is_empty() {
            return failed("no_valid_accounts");
        }

        self.ready = true;
        self.chain_id = chain_id;
        self.rpc_url = rpc_url.to_owned();
        self.accounts = accounts;
        self.wallets = wallets;
        self.chains = chains
            .iter()
            .filter_map(|chain| {
                chain
                    .get("id")
                    .or_else(|| chain.get("chain_id"))
                    .or_else(|| chain.get("chainId"))
                    .and_then(chain_id_value_to_i64)
                    .map(|id| (id, chain.clone()))
            })
            .collect();
        success(json!(self.accounts))
    }

    #[func]
    fn get_chain_id(&self) -> Dictionary {
        if !self.ready {
            return failed("not_ready");
        }
        success(json!(self.chain_id))
    }

    #[func]
    fn set_chain_id(&mut self, chain_id: i64, _config_json: GString) -> Dictionary {
        if !self.ready {
            return failed("not_ready");
        }
        if chain_id <= 0 {
            return failed("invalid_chain");
        }

        let Some(chain) = self.chains.get(&chain_id) else {
            return failed("invalid_chain");
        };
        let Some(rpc_url) = chain
            .get("rpc_url")
            .or_else(|| chain.get("rpcUrl"))
            .and_then(Value::as_str)
        else {
            return failed("invalid_chain");
        };

        self.chain_id = chain_id;
        self.rpc_url = rpc_url.to_owned();
        success(Value::Null)
    }

    #[func]
    fn get_accounts(&self) -> Dictionary {
        if !self.ready {
            return failed("not_ready");
        }
        success(json!(self.accounts))
    }

    #[func]
    fn request(&mut self, method: GString, params_json: GString) -> Dictionary {
        let method = method.to_string();
        if !self.ready && method != "eth_accounts" {
            return failed("not_ready");
        }
        if self.rpc_url.is_empty() {
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
            None => rpc_request(&self.rpc_url, &method, params),
        };

        match result {
            Ok(value) => success(value),
            Err(error) => error_response(error),
        }
    }

    #[func]
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
    fn keccak256(&self, bytes: PackedByteArray) -> Dictionary {
        let input = bytes.to_vec();
        let mut output = [0u8; 32];
        let mut hasher = Keccak::v256();
        hasher.update(&input);
        hasher.finalize(&mut output);
        success_bytes(output.to_vec())
    }

    #[func]
    fn from_wei(&self, amount: GString, unit: GString) -> Dictionary {
        convert_from_wei(&amount.to_string(), &unit.to_string())
    }

    #[func]
    fn to_wei(&self, amount: GString, unit: GString) -> Dictionary {
        convert_to_wei(&amount.to_string(), &unit.to_string())
    }

    #[func]
    fn to_checksum_address(&self, address: GString) -> Dictionary {
        let address = address.to_string();
        let Some(stripped) = normalize_address(&address) else {
            return failed("invalid_address");
        };
        success(json!(checksum_address(&stripped)))
    }

    #[func]
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
    fn abi_encode(&self, args_json: GString) -> Dictionary {
        let Ok(args) = serde_json::from_str::<Value>(&args_json.to_string()) else {
            return failed("invalid_args");
        };
        let Some(tokens) = abi_args_to_tokens(&args) else {
            return failed("invalid_args");
        };
        success_bytes(encode(&tokens))
    }

    #[func]
    fn abi_encode_packed(&self, args_json: GString) -> Dictionary {
        let Ok(args) = serde_json::from_str::<Value>(&args_json.to_string()) else {
            return failed("invalid_args");
        };
        let Some(tokens) = abi_args_to_tokens(&args) else {
            return failed("invalid_args");
        };
        match ethers_core::abi::encode_packed(&tokens) {
            Ok(bytes) => success_bytes(bytes),
            Err(_) => failed("invalid_value"),
        }
    }

    #[func]
    fn abi_decode(&self, bytes: PackedByteArray, spec_json: GString) -> Dictionary {
        let Ok(spec) = serde_json::from_str::<Value>(&spec_json.to_string()) else {
            return failed("invalid_spec");
        };
        let Some(types) = abi_spec_to_types(&spec) else {
            return failed("invalid_spec");
        };
        match ethers_core::abi::decode(&types, &bytes.to_vec()) {
            Ok(tokens) => success(Value::Array(
                tokens.into_iter().map(token_to_json).collect(),
            )),
            Err(_) => failed("invalid_value"),
        }
    }

    #[func]
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
        let Ok(data) = function.encode_input(&tokens) else {
            return failed("invalid_params");
        };

        if matches!(
            function.state_mutability,
            StateMutability::View | StateMutability::Pure
        ) {
            let call = merge_tx_json(
                &tx_params,
                &address,
                &format!("0x{}", hex::encode(data)),
                None,
            );
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
                    match function.decode_output(&bytes) {
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
        let hash = H256::from_slice(&keccak_bytes(&bytes));
        let signature = wallet
            .sign_hash(hash)
            .map_err(|error| json_rpc_error(-32000, &error.to_string()))?;
        Ok(json!(signature.to_string()))
    }

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
        let signature = block_on(wallet.sign_message(bytes))
            .map_err(|error| json_rpc_error(-32000, &error.to_string()))?;
        Ok(json!(signature.to_string()))
    }

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
        let signature = block_on(wallet.sign_typed_data(&typed_data))
            .map_err(|error| json_rpc_error(-32000, &error.to_string()))?;
        Ok(json!(signature.to_string()))
    }

    fn handle_sign_transaction(&self, params: &Value) -> Result<Value, Value> {
        let Some(values) = params.as_array() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        let Some(tx) = values.first() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        self.sign_transaction(tx)
    }

    fn handle_send_transaction(&self, params: &Value) -> Result<Value, Value> {
        let Some(values) = params.as_array() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        let Some(tx) = values.first() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        self.sign_and_send_tx(tx).map(Value::String)
    }

    fn handle_add_chain(&mut self, params: &Value) -> Result<Value, Value> {
        let Some(values) = params.as_array() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        let Some(chain) = values.first().and_then(Value::as_object) else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        let chain_id = chain
            .get("chainId")
            .and_then(Value::as_str)
            .and_then(hex_quantity_to_i64)
            .ok_or_else(|| json_rpc_error(-32602, "invalid chain id"))?;
        let rpc_url = chain
            .get("rpcUrls")
            .and_then(Value::as_array)
            .and_then(|urls| urls.first())
            .and_then(Value::as_str)
            .or_else(|| chain.get("rpc_url").and_then(Value::as_str))
            .or_else(|| chain.get("rpcUrl").and_then(Value::as_str))
            .ok_or_else(|| json_rpc_error(-32602, "missing rpc url"))?;

        let mut stored = Value::Object(chain.clone());
        if let Value::Object(ref mut object) = stored {
            object.insert("id".to_owned(), json!(chain_id));
            object.insert("rpc_url".to_owned(), json!(rpc_url));
        }
        self.chains.insert(chain_id, stored);
        Ok(Value::Null)
    }

    fn handle_switch_chain(&mut self, params: &Value) -> Result<Value, Value> {
        let Some(values) = params.as_array() else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        let Some(chain) = values.first().and_then(Value::as_object) else {
            return Err(json_rpc_error(-32602, "invalid params"));
        };
        let chain_id = chain
            .get("chainId")
            .and_then(Value::as_str)
            .and_then(hex_quantity_to_i64)
            .ok_or_else(|| json_rpc_error(4902, "unknown chain"))?;
        let Some(chain) = self.chains.get(&chain_id) else {
            return Err(json_rpc_error(4902, "unknown chain"));
        };
        let Some(rpc_url) = chain
            .get("rpc_url")
            .or_else(|| chain.get("rpcUrl"))
            .and_then(Value::as_str)
        else {
            return Err(json_rpc_error(4902, "unknown chain"));
        };
        self.chain_id = chain_id;
        self.rpc_url = rpc_url.to_owned();
        Ok(Value::Null)
    }

    fn wallet_for_value(&self, value: &Value) -> Option<LocalWallet> {
        let address = value.as_str().and_then(parse_address)?;
        self.wallets.get(&address).cloned()
    }

    fn wallet_for_tx(&self, tx: &Value) -> Option<LocalWallet> {
        tx.get("from")
            .and_then(|value| self.wallet_for_value(value))
            .or_else(|| self.wallets.values().next().cloned())
    }

    fn sign_transaction(&self, tx: &Value) -> Result<Value, Value> {
        let chain_id = tx
            .get("chainId")
            .or_else(|| tx.get("chain_id"))
            .and_then(chain_id_value_to_i64)
            .unwrap_or(self.chain_id);
        let wallet = self
            .wallet_for_tx(tx)
            .ok_or_else(|| json_rpc_error(4100, "unknown account"))?
            .with_chain_id(chain_id as u64);
        let typed = self.prepare_transaction(tx, wallet.address())?;
        let signature = block_on(wallet.sign_transaction(&typed))
            .map_err(|error| json_rpc_error(-32000, &error.to_string()))?;
        let raw = typed.rlp_signed(&signature);
        Ok(json!(format!("0x{}", hex::encode(raw))))
    }

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

    fn prepare_transaction(&self, tx: &Value, signer: Address) -> Result<TypedTransaction, Value> {
        let Some(to) = tx.get("to").and_then(Value::as_str).and_then(parse_address) else {
            return Err(json_rpc_error(-32602, "missing to"));
        };
        let data = tx
            .get("data")
            .and_then(Value::as_str)
            .and_then(decode_hex_bytes)
            .unwrap_or_default();
        let value = tx.get("value").and_then(value_to_u256).unwrap_or_default();
        let nonce = match tx.get("nonce").and_then(value_to_u256) {
            Some(value) => value,
            None => {
                let nonce = rpc_request(
                    &self.rpc_url,
                    "eth_getTransactionCount",
                    json!([format_address(signer), "pending"]),
                )?;
                value_to_u256(&nonce).ok_or_else(|| json_rpc_error(-32000, "invalid nonce"))?
            }
        };
        let gas = match tx
            .get("gas")
            .or_else(|| tx.get("gasLimit"))
            .and_then(value_to_u256)
        {
            Some(value) => value,
            None => {
                let estimate = rpc_request(&self.rpc_url, "eth_estimateGas", json!([tx]))?;
                value_to_u256(&estimate).ok_or_else(|| json_rpc_error(-32000, "invalid gas"))?
            }
        };
        if tx.get("maxFeePerGas").is_some() || tx.get("maxPriorityFeePerGas").is_some() {
            let max_fee_per_gas = tx
                .get("maxFeePerGas")
                .and_then(value_to_u256)
                .ok_or_else(|| json_rpc_error(-32602, "missing maxFeePerGas"))?;
            let max_priority_fee_per_gas =
                match tx.get("maxPriorityFeePerGas").and_then(value_to_u256) {
                    Some(value) => value,
                    None => rpc_request(&self.rpc_url, "eth_maxPriorityFeePerGas", json!([]))
                        .ok()
                        .and_then(|value| value_to_u256(&value))
                        .unwrap_or_default(),
                };
            let mut request = Eip1559TransactionRequest::new()
                .from(signer)
                .to(NameOrAddress::Address(to))
                .value(value)
                .data(Bytes::from(data))
                .nonce(nonce)
                .gas(gas)
                .max_fee_per_gas(max_fee_per_gas)
                .max_priority_fee_per_gas(max_priority_fee_per_gas);
            request.chain_id = Some(U64::from(
                tx.get("chainId")
                    .or_else(|| tx.get("chain_id"))
                    .and_then(chain_id_value_to_i64)
                    .unwrap_or(self.chain_id) as u64,
            ));
            Ok(TypedTransaction::Eip1559(request))
        } else {
            let gas_price = match tx.get("gasPrice").and_then(value_to_u256) {
                Some(value) => value,
                None => {
                    let gas_price = rpc_request(&self.rpc_url, "eth_gasPrice", json!([]))?;
                    value_to_u256(&gas_price)
                        .ok_or_else(|| json_rpc_error(-32000, "invalid gas price"))?
                }
            };
            let request = TransactionRequest::new()
                .from(signer)
                .to(NameOrAddress::Address(to))
                .value(value)
                .data(Bytes::from(data))
                .nonce(nonce)
                .gas(gas)
                .gas_price(gas_price)
                .chain_id(
                    tx.get("chainId")
                        .or_else(|| tx.get("chain_id"))
                        .and_then(chain_id_value_to_i64)
                        .unwrap_or(self.chain_id) as u64,
                );
            Ok(TypedTransaction::Legacy(request))
        }
    }

    fn contract_abi(&self, address: &str) -> Option<Abi> {
        let key = self.contracts.get(&checksum_or_lower(address))?;
        let abi_json = self.abis.get(key)?;
        serde_json::from_str::<Abi>(abi_json).ok()
    }
}

fn collect_accounts(config: &Value) -> (Vec<String>, HashMap<Address, LocalWallet>) {
    let mut wallets = HashMap::new();
    let mut accounts = Vec::new();

    if let Some(private_keys) = config
        .get("private_keys")
        .or_else(|| config.get("privateKeys"))
        .and_then(Value::as_array)
    {
        for key in private_keys.iter().filter_map(Value::as_str) {
            if let Ok(wallet) = LocalWallet::from_str(key) {
                accounts.push(format_address(wallet.address()));
                wallets.insert(wallet.address(), wallet);
            }
        }
    }

    if let Some(config_accounts) = config.get("accounts").and_then(Value::as_array) {
        for account in config_accounts {
            if let Some(key) = account
                .get("private_key")
                .or_else(|| account.get("privateKey"))
                .and_then(Value::as_str)
            {
                if let Ok(wallet) = LocalWallet::from_str(key) {
                    let address = format_address(wallet.address());
                    if !accounts.iter().any(|known| known == &address) {
                        accounts.push(address);
                    }
                    wallets.insert(wallet.address(), wallet);
                    continue;
                }
            }
            if let Some(address) = account
                .as_str()
                .or_else(|| account.get("address").and_then(Value::as_str))
            {
                if is_non_zero_address(address) {
                    let address = checksum_address(&normalize_address(address).unwrap());
                    if !accounts.iter().any(|known| known == &address) {
                        accounts.push(address);
                    }
                }
            }
        }
    }

    (accounts, wallets)
}

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

fn json_rpc_error(code: i64, message: &str) -> Value {
    json!({"code": code, "message": message})
}

fn parse_address(address: &str) -> Option<Address> {
    let bytes = decode_hex_bytes(address)?;
    if bytes.len() != 20 || bytes.iter().all(|byte| *byte == 0) {
        return None;
    }
    Some(Address::from_slice(&bytes))
}

fn format_address(address: Address) -> String {
    checksum_address(&hex::encode(address.as_bytes()))
}

fn checksum_or_lower(address: &str) -> String {
    normalize_address(address)
        .map(|address| checksum_address(&address))
        .unwrap_or_else(|| address.to_ascii_lowercase())
}

fn value_to_bytes(value: &Value) -> Option<Vec<u8>> {
    match value {
        Value::String(value) if value.starts_with("0x") => decode_hex_bytes(value),
        Value::String(value) => Some(value.as_bytes().to_vec()),
        _ => None,
    }
}

fn decode_hex_bytes(hex: &str) -> Option<Vec<u8>> {
    let stripped = hex.strip_prefix("0x").unwrap_or(hex);
    if stripped.len() % 2 != 0 || !stripped.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    hex::decode(stripped).ok()
}

fn hex_quantity_to_i64(hex: &str) -> Option<i64> {
    if !is_prefixed_hex_quantity(hex) {
        return None;
    }
    i64::from_str_radix(&hex[2..], 16).ok()
}

fn chain_id_value_to_i64(value: &Value) -> Option<i64> {
    match value {
        Value::Number(value) => value.as_i64(),
        Value::String(value) if value.starts_with("0x") => hex_quantity_to_i64(value),
        Value::String(value) => value.parse::<i64>().ok(),
        _ => None,
    }
}

fn value_to_u256(value: &Value) -> Option<U256> {
    match value {
        Value::String(value) if value.starts_with("0x") => {
            U256::from_str_radix(&value[2..], 16).ok()
        }
        Value::String(value) => U256::from_dec_str(value).ok(),
        Value::Number(value) => value.as_u64().map(U256::from),
        _ => None,
    }
}

fn u256_to_json(value: U256) -> Value {
    Value::String(value.to_string())
}

fn keccak_bytes(bytes: &[u8]) -> [u8; 32] {
    let mut output = [0u8; 32];
    let mut hasher = Keccak::v256();
    hasher.update(bytes);
    hasher.finalize(&mut output);
    output
}

fn merge_tx_json(tx_params: &Value, to: &str, data: &str, value: Option<&str>) -> Value {
    let mut tx = tx_params.as_object().cloned().unwrap_or_default();
    tx.insert("to".to_owned(), Value::String(to.to_owned()));
    tx.insert("data".to_owned(), Value::String(data.to_owned()));
    if let Some(value) = value {
        tx.insert("value".to_owned(), Value::String(value.to_owned()));
    }
    Value::Object(tx)
}

fn abi_args_to_tokens(args: &Value) -> Option<Vec<Token>> {
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

fn abi_spec_to_types(spec: &Value) -> Option<Vec<ParamType>> {
    let spec = spec.as_array()?;
    spec.iter().map(abi_spec_item_to_type).collect()
}

fn abi_spec_item_to_type(spec: &Value) -> Option<ParamType> {
    if let Some(type_name) = spec.as_str() {
        return parse_param_type(type_name);
    }
    let object = spec.as_object()?;
    parse_param_type(object.get("type")?.as_str()?)
}

fn parse_param_type(type_name: &str) -> Option<ParamType> {
    ethers_core::abi::param_type::Reader::read(type_name).ok()
}

fn values_to_param_tokens(values: &Value, params: &[Param]) -> Option<Vec<Token>> {
    let values = values.as_array()?;
    if values.len() != params.len() {
        return None;
    }
    values
        .iter()
        .zip(params)
        .map(|(value, param)| value_to_token(value, &param.kind))
        .collect()
}

fn value_to_token(value: &Value, kind: &ParamType) -> Option<Token> {
    match kind {
        ParamType::Address => Some(Token::Address(value.as_str().and_then(parse_address)?)),
        ParamType::Bytes => Some(Token::Bytes(value_to_bytes(value)?)),
        ParamType::FixedBytes(size) => {
            let bytes = value_to_bytes(value)?;
            if bytes.len() == *size {
                Some(Token::FixedBytes(bytes))
            } else {
                None
            }
        }
        ParamType::Int(_) => Some(Token::Int(value_to_u256(value)?)),
        ParamType::Uint(_) => Some(Token::Uint(value_to_u256(value)?)),
        ParamType::Bool => Some(Token::Bool(value.as_bool()?)),
        ParamType::String => Some(Token::String(value.as_str()?.to_owned())),
        ParamType::Array(inner) => {
            let values = value.as_array()?;
            values
                .iter()
                .map(|value| value_to_token(value, inner))
                .collect::<Option<Vec<_>>>()
                .map(Token::Array)
        }
        ParamType::FixedArray(inner, size) => {
            let values = value.as_array()?;
            if values.len() != *size {
                return None;
            }
            values
                .iter()
                .map(|value| value_to_token(value, inner))
                .collect::<Option<Vec<_>>>()
                .map(Token::FixedArray)
        }
        ParamType::Tuple(types) => {
            let values = value.as_array()?;
            if values.len() != types.len() {
                return None;
            }
            values
                .iter()
                .zip(types)
                .map(|(value, kind)| value_to_token(value, kind))
                .collect::<Option<Vec<_>>>()
                .map(Token::Tuple)
        }
    }
}

fn infer_token(value: &Value) -> Option<Token> {
    match value {
        Value::Bool(value) => Some(Token::Bool(*value)),
        Value::String(value) if value.starts_with("0x") => {
            decode_hex_bytes(value).map(Token::Bytes)
        }
        Value::String(value) if is_decimal_uint(value) => {
            U256::from_dec_str(value).ok().map(Token::Uint)
        }
        Value::String(value) => Some(Token::String(value.clone())),
        Value::Number(value) => value.as_u64().map(|value| Token::Uint(U256::from(value))),
        Value::Array(values) => values
            .iter()
            .map(infer_token)
            .collect::<Option<Vec<_>>>()
            .map(Token::Array),
        _ => None,
    }
}

fn token_to_json(token: Token) -> Value {
    match token {
        Token::Address(value) => Value::String(format_address(value)),
        Token::FixedBytes(value) | Token::Bytes(value) => {
            Value::String(format!("0x{}", hex::encode(value)))
        }
        Token::Int(value) | Token::Uint(value) => u256_to_json(value),
        Token::Bool(value) => Value::Bool(value),
        Token::String(value) => Value::String(value),
        Token::FixedArray(values) | Token::Array(values) | Token::Tuple(values) => {
            Value::Array(values.into_iter().map(token_to_json).collect())
        }
    }
}

fn resolve_function(abi: &Abi, method: &Value, params: &Value) -> Option<Function> {
    if let Some(name) = method.as_str() {
        let arity = params.as_array().map(Vec::len).unwrap_or_default();
        return abi
            .functions_by_name(name)
            .ok()?
            .iter()
            .find(|function| function.inputs.len() == arity)
            .cloned();
    }
    serde_json::from_value::<Function>(method.clone()).ok()
}

fn resolve_event(abi: &Abi, event: &Value) -> Option<Event> {
    if let Some(name) = event.as_str() {
        return abi.events_by_name(name).ok()?.first().cloned();
    }
    serde_json::from_value::<Event>(event.clone()).ok()
}

fn event_filter_topics(event: &Event, topics: &Value) -> Option<Vec<Value>> {
    let mut output = vec![Value::String(format!("{:#x}", event.signature()))];
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
                let token = value_to_token(value, &input.kind)?;
                let topic = if input.kind.is_dynamic() {
                    format!("0x{}", hex::encode(keccak_bytes(&encode(&[token]))))
                } else {
                    format!("0x{}", hex::encode(encode(&[token])))
                };
                output.push(Value::String(topic));
            }
        }
        return Some(output);
    }
    None
}

fn decode_event_log(event: &Event, log: &Value) -> Option<Value> {
    let topics: Vec<H256> = log
        .get("topics")?
        .as_array()?
        .iter()
        .map(|topic| {
            let bytes = decode_hex_bytes(topic.as_str()?)?;
            if bytes.len() != 32 {
                return None;
            }
            Some(H256::from_slice(&bytes))
        })
        .collect::<Option<Vec<_>>>()?;
    if topics.first().copied()? != event.signature() {
        return None;
    }
    let data = decode_hex_bytes(log.get("data")?.as_str()?)?;
    let decoded = event.parse_log(RawLog { topics, data }).ok()?;
    let mut args = serde_json::Map::new();
    for (index, param) in decoded.params.into_iter().enumerate() {
        let name = if param.name.is_empty() {
            index.to_string()
        } else {
            param.name
        };
        args.insert(name, token_to_json(param.value));
    }
    Some(json!({
        "name": event.name,
        "args": args,
        "rawLog": log,
    }))
}

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

fn convert_to_wei(amount: &str, unit: &str) -> Dictionary {
    let Some(decimals) = unit_decimals(unit) else {
        return failed("invalid_unit");
    };
    let Some(value) = parse_units(amount, decimals) else {
        return failed("invalid_amount");
    };
    success(json!(value.to_str_radix(10)))
}

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

fn keccak_hex(bytes: &[u8]) -> String {
    let mut output = [0u8; 32];
    let mut hasher = Keccak::v256();
    hasher.update(bytes);
    hasher.finalize(&mut output);
    hex::encode(output)
}

fn normalize_address(address: &str) -> Option<String> {
    let stripped = address.strip_prefix("0x").unwrap_or(address);
    if stripped.len() != 40 || !stripped.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(stripped.to_owned())
}

fn is_non_zero_address(address: &str) -> bool {
    normalize_address(address)
        .map(|stripped| stripped.chars().any(|c| c != '0'))
        .unwrap_or(false)
}

fn ensure_0x(address: &str) -> String {
    if address.starts_with("0x") {
        address.to_owned()
    } else {
        format!("0x{address}")
    }
}

fn is_identifier(key: &str) -> bool {
    !key.is_empty() && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn is_decimal_uint(value: &str) -> bool {
    !value.is_empty() && value.chars().all(|c| c.is_ascii_digit())
}

fn is_int_size(size: i64) -> bool {
    size >= 8 && size <= 256 && size % 8 == 0
}

fn is_prefixed_hex_quantity(hex: &str) -> bool {
    hex.starts_with("0x")
        && hex.len() > 2
        && !hex[2..].contains("0x")
        && (hex.len() == 3 || !hex[2..].starts_with('0'))
        && hex[2..].chars().all(|c| c.is_ascii_hexdigit())
}

fn is_named_block_tag(tag: &str) -> bool {
    matches!(
        tag,
        "earliest" | "latest" | "pending" | "safe" | "finalized"
    )
}

fn success(value: Value) -> Dictionary {
    let mut dictionary = Dictionary::new();
    dictionary.set("ok", true);
    dictionary.set("value", json_to_variant(value));
    dictionary
}

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

fn failed(error: &str) -> Dictionary {
    let mut dictionary = Dictionary::new();
    dictionary.set("ok", false);
    dictionary.set("error", error);
    dictionary
}

fn error_response(error: Value) -> Dictionary {
    let mut dictionary = Dictionary::new();
    dictionary.set("ok", false);
    dictionary.set("error", json_to_variant(error));
    dictionary
}

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

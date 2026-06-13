use godot::builtin::{Array, Dictionary, GString, PackedByteArray, Variant};
use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;
use num_bigint::{BigInt, BigUint};
use num_traits::{One, Zero};
use serde_json::{json, Value};
use std::collections::HashMap;
use tiny_keccak::{Hasher, Keccak};

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct AlephVaultEvmNativeWallet {
    base: Base<RefCounted>,
    ready: bool,
    chain_id: i64,
    rpc_url: String,
    accounts: Vec<String>,
    abis: HashMap<String, String>,
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
            abis: HashMap::new(),
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
            .and_then(Value::as_i64)
            .or_else(|| {
                chains
                    .first()
                    .and_then(|chain| chain.get("id"))
                    .and_then(Value::as_i64)
            });

        let Some(chain_id) = selected_chain_id else {
            return failed("no_valid_chains");
        };

        let Some(chain) = chains
            .iter()
            .find(|chain| chain.get("id").and_then(Value::as_i64) == Some(chain_id))
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

        let accounts = collect_accounts(&config);
        if accounts.is_empty() {
            return failed("no_valid_accounts");
        }

        self.ready = true;
        self.chain_id = chain_id;
        self.rpc_url = rpc_url.to_owned();
        self.accounts = accounts;
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
    fn set_chain_id(&mut self, chain_id: i64, config_json: GString) -> Dictionary {
        if !self.ready {
            return failed("not_ready");
        }
        if chain_id <= 0 {
            return failed("invalid_chain");
        }

        let Ok(config) = serde_json::from_str::<Value>(&config_json.to_string()) else {
            return failed("invalid_chain");
        };
        let Some(chains) = config.get("chains").and_then(Value::as_array) else {
            return failed("invalid_chain");
        };
        let Some(chain) = chains
            .iter()
            .find(|chain| chain.get("id").and_then(Value::as_i64) == Some(chain_id))
        else {
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
    fn request(&self, method: GString, params_json: GString) -> Dictionary {
        if !self.ready && method.to_string() != "eth_accounts" {
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

        match rpc_request(&self.rpc_url, &method.to_string(), params) {
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
    fn abi_encode(&self, _args_json: GString) -> Dictionary {
        failed("incomplete_binding")
    }

    #[func]
    fn abi_encode_packed(&self, _args_json: GString) -> Dictionary {
        failed("incomplete_binding")
    }

    #[func]
    fn abi_decode(&self, _bytes: PackedByteArray, _spec_json: GString) -> Dictionary {
        failed("incomplete_binding")
    }

    #[func]
    fn contract_create(&self, address: GString, abi_key: GString) -> Dictionary {
        let address = address.to_string();
        if !is_non_zero_address(&address) {
            return failed("invalid_address");
        }
        if !self.abis.contains_key(&abi_key.to_string()) {
            return failed("not_found");
        }
        success(Value::Null)
    }

    #[func]
    fn contract_invoke(
        &self,
        _address: GString,
        _method_json: GString,
        _params_json: GString,
        _tx_params_json: GString,
    ) -> Dictionary {
        failed("incomplete_binding")
    }

    #[func]
    fn contract_get_events(
        &self,
        _address: GString,
        _event_json: GString,
        _topics_json: GString,
        _from: GString,
        _to: GString,
    ) -> Dictionary {
        failed("incomplete_binding")
    }

    #[func]
    fn contract_get_tx_events(&self, _tx_obj_json: GString, _event_json: GString) -> Dictionary {
        failed("incomplete_binding")
    }
}

fn collect_accounts(config: &Value) -> Vec<String> {
    config
        .get("accounts")
        .and_then(Value::as_array)
        .map(|accounts| {
            accounts
                .iter()
                .filter_map(|account| {
                    account
                        .as_str()
                        .or_else(|| account.get("address").and_then(Value::as_str))
                })
                .filter(|address| is_non_zero_address(address))
                .map(|address| checksum_address(&normalize_address(address).unwrap()))
                .collect()
        })
        .unwrap_or_default()
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

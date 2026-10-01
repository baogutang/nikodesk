use hbb_common::{
    anyhow::anyhow,
    bail,
    config::Config,
    get_time,
    password_security::{decrypt_vec_or_original, encrypt_vec_or_original},
    ResultType,
};
use serde_derive::{Deserialize, Serialize};
use std::sync::Mutex;
use totp_rs::{Algorithm, Secret, TOTP};

lazy_static::lazy_static! {
    static ref CURRENT_2FA: Mutex<Option<Pending2fa>> = Mutex::new(None);
}
#[cfg(feature="nikodesk")]
type Pending2fa = (TOTPInfo, TOTP, std::time::Instant);
#[cfg(not(feature="nikodesk"))]
type Pending2fa = (TOTPInfo, TOTP);

#[cfg(not(feature="nikodesk"))]
const ISSUER: &str = "RustDesk";
#[cfg(feature="nikodesk")]
const ISSUER: &str = "NikoDesk";
const TAG_LOGIN: &str = "Connection";

#[derive(Clone, Default, Serialize, Deserialize)]
#[cfg_attr(not(feature="nikodesk"), derive(Debug))]
#[cfg_attr(feature="nikodesk", serde(deny_unknown_fields))]
pub struct TOTPInfo {
    pub name: String,
    pub secret: Vec<u8>,
    pub digits: usize,
    pub created_at: i64,
}
#[cfg(feature="nikodesk")]
impl Drop for TOTPInfo {
    fn drop(&mut self) {hbb_common::sodiumoxide::utils::memzero(&mut self.secret);}
}

impl TOTPInfo {
    fn new_totp(&self) -> ResultType<TOTP> {
        let totp = TOTP::new(
            Algorithm::SHA1,
            self.digits,
            1,
            30,
            self.secret.clone(),
            Some(format!("{} {}", ISSUER, TAG_LOGIN)),
            self.name.clone(),
        )?;
        Ok(totp)
    }

    fn gen_totp_info(name: String, digits: usize) -> ResultType<TOTPInfo> {
        let secret = Secret::generate_secret();
        let totp = TOTPInfo {
            secret: secret.to_bytes()?,
            name,
            digits,
            created_at: get_time(),
            ..Default::default()
        };
        Ok(totp)
    }

    pub fn into_string(&self) -> ResultType<String> {
        let secret = encrypt_vec_or_original(self.secret.as_slice(), "00", 1024);
        #[cfg(feature="nikodesk")]
        {
            let (mut decoded, confirmed, _) = decrypt_vec_or_original(&secret, "00");
            let verified = confirmed && decoded == self.secret;
            hbb_common::sodiumoxide::utils::memzero(&mut decoded);
            if !verified {bail!("Two-factor secret encryption is unavailable");}
        }
        let mut totp_info = self.clone();
        #[cfg(feature="nikodesk")]
        hbb_common::sodiumoxide::utils::memzero(&mut totp_info.secret);
        totp_info.secret = secret;
        let s = serde_json::to_string(&totp_info)?;
        Ok(s)
    }

    pub fn from_str(data: &str) -> ResultType<TOTP> {
        #[cfg(feature="nikodesk")]
        if data.len() > 16 * 1024 {bail!("Invalid two-factor configuration");}
        let mut totp_info = serde_json::from_str::<TOTPInfo>(data)?;
        #[cfg(feature="nikodesk")]
        if ![6,8].contains(&totp_info.digits) || totp_info.name.is_empty() || totp_info.name.len() > 256
            || totp_info.name.chars().any(char::is_control) || totp_info.created_at < 0
            || totp_info.secret.len() > 1024 {bail!("Invalid two-factor configuration");}
        let (secret, success, _) = decrypt_vec_or_original(&totp_info.secret, "00");
        if success {
            totp_info.secret = secret;
            #[cfg(feature="nikodesk")]
            if !(16..=64).contains(&totp_info.secret.len()) {bail!("Invalid two-factor configuration");}
            return Ok(totp_info.new_totp()?);
        } else {
            bail!("decrypt_vec_or_original 2fa secret failed")
        }
    }
}

pub fn generate2fa() -> String {
    #[cfg(feature="nikodesk")]
    if let Some((mut info, mut totp, _)) = CURRENT_2FA.lock().unwrap().take() {
        hbb_common::sodiumoxide::utils::memzero(&mut info.secret);
        hbb_common::sodiumoxide::utils::memzero(&mut totp.secret);
    }
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let id = crate::ipc::get_id();
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let id = Config::get_id();
    if let Ok(info) = TOTPInfo::gen_totp_info(id, 6) {
        if let Ok(totp) = info.new_totp() {
            let code = totp.get_url();
            #[cfg(feature="nikodesk")]
            { *CURRENT_2FA.lock().unwrap() = Some((info, totp, std::time::Instant::now())); }
            #[cfg(not(feature="nikodesk"))]
            { *CURRENT_2FA.lock().unwrap() = Some((info, totp)); }
            return code;
        }
    }
    "".to_owned()
}

pub fn verify2fa(code: String) -> bool {
    #[cfg(feature="nikodesk")]
    {
        let Ok(mut pending) = CURRENT_2FA.lock() else {return false;};
        let Some((info, totp, created)) = pending.as_ref() else {return false;};
        let expired = created.elapsed() >= std::time::Duration::from_secs(300);
        let confirmed = !expired && totp.check_current(&code).unwrap_or(false)
            && crate::nikodesk::totp_replay::consume(totp, &code).unwrap_or(false)
            && info.into_string().is_ok_and(|value| crate::ipc::set_niko_option("2fa", &value).is_ok());
        if confirmed || expired {
            if let Some((mut info, mut totp, _)) = pending.take() {
                hbb_common::sodiumoxide::utils::memzero(&mut info.secret);
                hbb_common::sodiumoxide::utils::memzero(&mut totp.secret);
            }
        }
        return confirmed;
    }
    #[cfg(not(feature="nikodesk"))]
    if let Some((info, totp)) = CURRENT_2FA.lock().unwrap().as_ref() {
        if let Ok(res) = totp.check_current(&code) {
            if res {
                if let Ok(v) = info.into_string() {
                    #[cfg(feature = "nikodesk")]
                    if crate::ipc::set_niko_option("2fa", &v).is_err() { return false; }
                    #[cfg(all(not(feature = "nikodesk"), not(any(target_os = "android", target_os = "ios"))))]
                    crate::ipc::set_option("2fa", &v);
                    #[cfg(all(not(feature = "nikodesk"), any(target_os = "android", target_os = "ios")))]
                    Config::set_option("2fa".to_owned(), v);
                    return res;
                }
            }
        }
    }
    #[cfg(not(feature="nikodesk"))]
    {false}
}

#[cfg(feature="nikodesk")]
pub(crate) fn get_2fa_checked(raw: Option<String>) -> ResultType<Option<TOTP>> {
    let value = raw.unwrap_or_else(|| Config::get_option("2fa"));
    if value.is_empty() {return Ok(None);}
    TOTPInfo::from_str(&value).map(Some).map_err(|_| anyhow!("Two-factor configuration is invalid"))
}
#[cfg(feature="nikodesk")]
pub(crate) fn configuration_status(raw: Option<String>) -> &'static str {
    match get_2fa_checked(raw) {
        Ok(None) => "disabled",
        Ok(Some(mut totp)) => {
            let available = crate::nikodesk::totp_replay::status(&totp).is_ok();
            hbb_common::sodiumoxide::utils::memzero(&mut totp.secret);
            if available {"enabled"} else {"invalid"}
        }
        Err(_) => "invalid",
    }
}
#[cfg(feature="nikodesk")]
pub(crate) fn check_login_code(totp: &TOTP, code: &str) -> ResultType<bool> {
    let Some(mut current) = get_2fa_checked(None)? else {bail!("Two-factor settings changed");};
    let same_factor = hbb_common::sodiumoxide::utils::memcmp(
        &crate::nikodesk::totp_replay::factor(totp), &crate::nikodesk::totp_replay::factor(&current));
    hbb_common::sodiumoxide::utils::memzero(&mut current.secret);
    if !same_factor {bail!("Two-factor settings changed");}
    crate::nikodesk::totp_replay::consume(totp, code)
}

#[cfg(all(test,feature="nikodesk"))]
mod nikodesk_two_factor_tests {
    use super::*;
    #[test]
    fn invalid_or_unencrypted_config_is_never_interpreted_as_a_disabled_factor() {
        assert!(get_2fa_checked(Some(String::new())).unwrap().is_none());
        assert_eq!(configuration_status(Some(String::new())), "disabled");
        let unencrypted = TOTPInfo {name:"synthetic-fixture".into(), secret:vec![17;20], digits:6, created_at:1};
        for raw in [" ".to_owned(), "null".to_owned(), "{}".to_owned(), "x".repeat(16*1024+1),
            serde_json::to_string(&unencrypted).unwrap()] {
            assert!(get_2fa_checked(Some(raw.clone())).is_err());
            assert_eq!(configuration_status(Some(raw)), "invalid");
        }
    }
}

pub fn get_2fa(raw: Option<String>) -> Option<TOTP> {
    TOTPInfo::from_str(&raw.unwrap_or(Config::get_option("2fa")))
        .map(|x| Some(x))
        .unwrap_or_default()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TelegramBot {
    #[serde(skip)]
    pub token_str: String,
    pub token: Vec<u8>,
    pub chat_id: String,
}

impl TelegramBot {
    fn into_string(&self) -> ResultType<String> {
        let token = encrypt_vec_or_original(self.token_str.as_bytes(), "00", 1024);
        let bot = TelegramBot {
            token,
            ..self.clone()
        };
        let s = serde_json::to_string(&bot)?;
        Ok(s)
    }

    fn save(&self) -> ResultType<()> {
        let s = self.into_string()?;
        #[cfg(feature = "nikodesk")]
        crate::ipc::set_niko_option("bot", &s)?;
        #[cfg(all(not(feature = "nikodesk"), not(any(target_os = "android", target_os = "ios"))))]
        crate::ipc::set_option("bot", &s);
        #[cfg(all(not(feature = "nikodesk"), any(target_os = "android", target_os = "ios")))]
        Config::set_option("bot".to_owned(), s);
        Ok(())
    }

    pub fn get() -> ResultType<Option<TelegramBot>> {
        let data = Config::get_option("bot");
        if data.is_empty() {
            return Ok(None);
        }
        let mut bot = serde_json::from_str::<TelegramBot>(&data)?;
        let (token, success, _) = decrypt_vec_or_original(&bot.token, "00");
        if success {
            bot.token_str = String::from_utf8(token)?;
            return Ok(Some(bot));
        }
        bail!("decrypt_vec_or_original telegram bot token failed")
    }
}

// https://gist.github.com/dideler/85de4d64f66c1966788c1b2304b9caf1
pub async fn send_2fa_code_to_telegram(text: &str, bot: TelegramBot) -> ResultType<()> {
    let url = format!("https://api.telegram.org/bot{}/sendMessage", bot.token_str);
    let params = serde_json::json!({"chat_id": bot.chat_id, "text": text});
    crate::post_request(url, params.to_string(), "").await?;
    Ok(())
}

pub fn get_chatid_telegram(bot_token: &str) -> ResultType<Option<String>> {
    let url = format!("https://api.telegram.org/bot{}/getUpdates", bot_token);
    // because caller is in tokio runtime, so we must call post_request_sync in new thread.
    let handle = std::thread::spawn(move || crate::post_request_sync(url, "".to_owned(), ""));
    let resp = handle.join().map_err(|_| anyhow!("Thread panicked"))??;
    let value = serde_json::from_str::<serde_json::Value>(&resp).map_err(|e| anyhow!(e))?;

    // Check for an error_code in the response
    if let Some(error_code) = value.get("error_code").and_then(|code| code.as_i64()) {
        // If there's an error_code, try to use the description for the error message
        let description = value["description"]
            .as_str()
            .unwrap_or("Unknown error occurred");
        return Err(anyhow!(
            "Telegram API error: {} (error_code: {})",
            description,
            error_code
        ));
    }

    let chat_id = &value["result"][0]["message"]["chat"]["id"];
    let chat_id = if let Some(id) = chat_id.as_i64() {
        Some(id.to_string())
    } else if let Some(id) = chat_id.as_str() {
        Some(id.to_owned())
    } else {
        None
    };

    if let Some(chat_id) = chat_id.as_ref() {
        let bot = TelegramBot {
            token_str: bot_token.to_owned(),
            chat_id: chat_id.to_owned(),
            ..Default::default()
        };
        bot.save()?;
    }

    Ok(chat_id)
}

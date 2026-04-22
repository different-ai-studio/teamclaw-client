pub mod client;
pub mod config;
pub mod error;

pub use client::{AgentRuntimeUpsert, ClaimResult, SupabaseClient};
pub use config::SupabaseConfig;
pub use error::{SupabaseError, SupabaseResult};

pub const SUPABASE_URL: &str = env!(
    "SUPABASE_URL",
    "SUPABASE_URL env var required at compile time"
);
pub const SUPABASE_ANON_KEY: &str = env!(
    "SUPABASE_ANON_KEY",
    "SUPABASE_ANON_KEY env var required at compile time"
);

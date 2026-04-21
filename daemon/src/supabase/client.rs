use crate::supabase::error::SupabaseResult;

pub struct SupabaseClient;

impl SupabaseClient {
    pub fn new() -> SupabaseResult<Self> {
        Ok(Self)
    }
}

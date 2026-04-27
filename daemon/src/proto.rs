pub mod amux {
    include!(concat!(env!("OUT_DIR"), "/amux.rs"));
}

use prost::Message;

// Helper trait for encode_to_vec on all proto messages
macro_rules! impl_encode {
    ($($t:ty),*) => {
        $(
            impl $t {
                pub fn encode_to_vec(&self) -> Vec<u8> {
                    let mut buf = Vec::with_capacity(self.encoded_len());
                    self.encode(&mut buf).expect(concat!("encode ", stringify!($t)));
                    buf
                }
            }
        )*
    };
}

impl_encode!(
    amux::Envelope,
    amux::DeviceState,
    amux::AgentList,
    amux::RuntimeInfo,
    amux::PeerList,
    amux::MemberList,
    amux::WorkspaceList
);

pub mod teamclaw {
    include!(concat!(env!("OUT_DIR"), "/teamclaw.rs"));
}

impl_encode!(
    teamclaw::SessionMessageEnvelope,
    teamclaw::IdeaEvent,
    teamclaw::RpcRequest,
    teamclaw::RpcResponse,
    teamclaw::Notify
);

impl amux::RuntimeCommandEnvelope {
    pub fn decode_from(buf: &[u8]) -> crate::error::Result<Self> {
        Ok(Self::decode(buf)?)
    }
}

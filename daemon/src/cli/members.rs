use crate::config::MemberStore;

pub fn run_list() -> anyhow::Result<()> {
    let store = MemberStore::load(&MemberStore::default_path())?;

    if store.members.is_empty() {
        println!("No members registered. Run `amuxd init` first.");
        return Ok(());
    }

    println!("Members:");
    for m in &store.members {
        let role = if m.is_owner() { "owner" } else { "member" };
        println!("  {} — {} ({})", m.member_id, m.display_name, role);
    }

    if !store.pending_invites.is_empty() {
        println!("\nPending invites:");
        for i in &store.pending_invites {
            let status = if i.is_expired() { "EXPIRED" } else { "pending" };
            println!("  {}… — {} ({})", &i.invite_token[..8], i.display_name, status);
        }
    }

    Ok(())
}

pub fn run_remove(member_id: &str) -> anyhow::Result<()> {
    let mut store = MemberStore::load(&MemberStore::default_path())?;

    if let Some(m) = store.members.iter().find(|m| m.member_id == member_id) {
        if m.is_owner() {
            println!("Cannot remove the owner.");
            return Ok(());
        }
    }

    if store.remove_member(member_id) {
        store.save(&MemberStore::default_path())?;
        println!("Member {} removed.", member_id);
    } else {
        println!("Member {} not found.", member_id);
    }

    Ok(())
}

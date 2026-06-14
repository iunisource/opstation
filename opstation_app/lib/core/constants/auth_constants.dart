/// The super admin's login email — the one account that sits above all orgs.
/// Kept in a single place so the sign-in check and the local seed can never
/// drift apart. Must be lowercase (sign-in compares the lowercased input).
const String kSuperAdminEmail = 'iunisource@gmail.com';

/// Stable local id for the seeded super-admin row. We locate the local session
/// record by this id rather than by email, so changing [kSuperAdminEmail] never
/// strands devices that were seeded under an older address.
const String kSuperAdminLocalId = 'u_super';

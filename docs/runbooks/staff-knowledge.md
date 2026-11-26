# Staff knowledge workspace

Keep `VGAS_STAFF_AUTH_ENABLED` unset or `false` until the VGAS-9 owner
decisions below are recorded. Follow the [staff sign-in and recovery
runbook](staff-auth.md) for the Entra registration, protected environment
configuration and verified identities. After approval, set the flag to
`true` and reload the intended instance through its approved operational
process. Verify the public `/health` response and sign in at `/staff/entra`.
Open `/staff/knowledge` from the registered HTTPS origin.

## Editorial workflow

1. An administrator creates a collection, then enables it when approved.
   An administrator can disable an active collection or retire a disabled one.
   Retirement is terminal. To configure a grant, look up a known assistant
   draft ID, check the displayed revision and confirm the grant or removal.
2. A scoped editor selects **New article** or opens an article and selects
   **New revision**. Enter the FAQ text, applicability, language variants,
   dates with explicit UTC offsets and source references. **Save draft**
   opens the revision. **Edit draft** changes its content, and **Submit for
   review** freezes the displayed snapshot for review. Use **Withdraw
   revision** to end work on a draft or pending review.
3. A scoped reviewer checks the source and displayed text. **Request
   changes** returns the revision to draft. **Approve revision** requires
   independent source verification in this workspace. A contributor asks
   another scoped reviewer to approve. Sensitive revisions cannot be
   approved through this workflow.
4. **Request publication** is a separate confirmation on an approved
   revision. The publisher checks the expected current revision and index
   generation before activation. **Refresh status** checks both locale
   indexes. For a failed publish, read the displayed reason and confirm
   **Retry publication** against the current snapshot. A stale confirmation
   requires a reload. Reindex applies to the current eligible revision.
5. A scoped reviewer can revoke an approved or published revision, or archive
   the article when it is obsolete. Read the affected revision or article
   before confirming. Index rollback in the UI is limited to the supported
   TEST fixture with a retained generation.

## Import and export

- Editors open **Import drafts** from a scoped active collection. Select one
  portable version 1 JSON file up to 262,144 bytes, containing at most ten
  articles. **Preview file** shows whether each entry creates an article or
  matches an existing draft. For an existing article requiring a new
  revision, choose the matching article by ID and preview again. Confirm
  **Apply draft import** only after checking the outcomes. A changed input,
  cancellation, access loss or expiry clears the preview. On a conflict or
  failure, prepare a new preview before retrying. The import creates drafts
  and matching-draft replay returns the existing draft.
- Reviewers can select one to ten active articles on a collection page and
  choose **Download JSON**. The request uses a CSRF-protected URL-encoded
  form up to 4 KiB. The download contains each selected article's latest
  portable content, which can include drafts and private source references.
  Keep downloads in approved staff storage. Importing restores draft
  content. Review and publication must happen in the destination.
- VGAS-11 and owner permission govern the staged FAQ import. Use synthetic
  files for local rehearsal.

## Logging and recovery

Domain mutations keep their existing scoped audit entries with operational
metadata such as the action, reason, target and revision state. Staff
request and channel logs are suppressed. Crash reporting retains fixed
notices while dropping request and form data, upload content, staff and
session identifiers, cookies, CSRF values and signed tokens. The views do
their work synchronously. Uploads use LiveView's supervised temporary files,
which it removes when consumed or when the upload process exits.

To disable access, set `VGAS_STAFF_AUTH_ENABLED=false` and reload the
instance. Verify that a staff request and a new socket connection are
denied, and check that `/health` still returns 200. Existing sockets recheck
access at their next event and disconnect at their original deadline.
Reverting the web change removes the workspace and preserves knowledge
records and audit history. Use the existing domain procedures for revocation
or publication recovery.

## VGAS-9 owner decisions

Verify the real Entra identity and local role behavior, the trusted TLS
ingress and request limits, and the currently patched authentication pins
before any staff trial. Approve a server-owned collection membership
mapping and public source-link allowlist. Both are fixture-only today.
Decide whether ordinary sign-out must invalidate an already connected tab
or a copied cookie immediately. Current sign-out clears the browser cookie,
and an outstanding credential can stay valid for the remainder of its
ten-minute lifetime unless the staff generation or registration changes.
Record the release owner's approval before enabling staff access.

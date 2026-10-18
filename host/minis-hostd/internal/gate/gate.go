// Package gate decides, from a candidate alone, whether it pushes, is only stored, or is dropped.
package gate

type Action string

const (
	ActionPush      Action = "push"
	ActionStoreOnly Action = "store_only"
	ActionDrop      Action = "drop"
)

// Reasons are stored with each event and shown by `events list`, so their spelling is a contract.
const (
	ReasonAllowed               = "allowed"
	ReasonMalformedSender       = "malformed_sender"
	ReasonTooOld                = "too_old"
	ReasonAutomated             = "automated"
	ReasonSenderNotAllowed      = "sender_not_allowed"
	ReasonSenderUnauthenticated = "sender_unauthenticated"
	ReasonReasonNotKept         = "reason_not_kept"
	ReasonRepoNotKept           = "repo_not_kept"
)

type Decision struct {
	Action Action
	Reason string
}

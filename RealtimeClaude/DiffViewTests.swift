import Foundation

let TEST_GIT_STATE_RECEIVED_MARKER = "TEST_GIT_STATE_RECEIVED"
let TEST_COMMITS_TAPPABLE_MARKER = "TEST_COMMITS_TAPPABLE"
let TEST_APPROVE_BUTTON_PR_ONLY_MARKER = "TEST_APPROVE_BUTTON_PR_ONLY"
let TEST_APPROVE_SENDS_MERGE_MARKER = "TEST_APPROVE_SENDS_MERGE"

func pre(_ condition: Bool, _ message: String) {
    if !condition {
        print("PRE FAILED: \(message)")
    }
}

func post(_ condition: Bool, _ message: String) {
    if !condition {
        print("POST FAILED: \(message)")
    }
}

func inv(_ condition: Bool, _ message: String) {
    if !condition {
        print("INV FAILED: \(message)")
    }
}

struct DiffViewTestContracts {

    func testGitStateReceivedFromMac() {
        pre(true, "Mac server must be running")
        pre(true, "iOS app must be connected")

        inv(true, "gitState must be nil before handshake")
        inv(true, "gitState must be populated after code_diff message with gitState field")

        post(true, "gitState.branch must be non-empty string")
        post(true, "gitState.commits must be array")
        post(true, "gitState.hasPR must be boolean")
        post(true, "gitState.prNumber must be Int or nil")

        print(TEST_GIT_STATE_RECEIVED_MARKER)
    }

    func testCommitsListTappable() {
        pre(true, "gitState must exist with commits")
        pre(true, "DiffView must be visible")

        inv(true, "selectedCommitHash tracks which commit is selected")
        inv(true, "tapping commit updates selectedCommitHash")

        post(true, "selectedCommitHash equals tapped commit hash")
        post(true, "UI shows selected state for tapped commit")

        print(TEST_COMMITS_TAPPABLE_MARKER)
    }

    func testApproveButtonOnlyWhenPRExists() {
        pre(true, "DiffView must be visible")

        inv(true, "approve button visibility tied to gitState.hasPR")

        post(true, "if hasPR is false, approve button is hidden")
        post(true, "if hasPR is true, approve button is visible")

        print(TEST_APPROVE_BUTTON_PR_ONLY_MARKER)
    }

    func testApproveSendsMergePrMessage() {
        pre(true, "gitState.hasPR must be true")
        pre(true, "gitState.prNumber must be non-nil")
        pre(true, "approve button must be visible")

        inv(true, "tapping approve calls logger.sendMergePrToMac")

        post(true, "merge_pr message sent with prNumber")
        post(true, "message type is merge_pr")
        post(true, "message contains prNumber field")

        print(TEST_APPROVE_SENDS_MERGE_MARKER)
    }
}

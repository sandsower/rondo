import gleeunit/should
import rondo/issue.{Blocker, Issue}
import rondo/tracker/linear

pub fn decode_single_issue_test() {
  let json = "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"abc-123\",\"identifier\":\"DAL-42\",\"title\":\"Fix login\",\"description\":\"Login is broken\",\"priority\":1,\"state\":{\"name\":\"Todo\"},\"branchName\":\"dal-42-fix-login\",\"url\":\"https://linear.app/dal/issue/DAL-42\",\"assignee\":{\"id\":\"user-1\"},\"labels\":{\"nodes\":[{\"name\":\"bug\"},{\"name\":\"frontend\"}]},\"relations\":{\"nodes\":[]}}]}}}"
  let issues = linear.decode_issues(json)
  issues
  |> should.equal([
    Issue(
      id: "abc-123",
      identifier: "DAL-42",
      title: "Fix login",
      description: "Login is broken",
      priority: 1,
      state: "Todo",
      branch_name: "dal-42-fix-login",
      url: "https://linear.app/dal/issue/DAL-42",
      assignee_id: "user-1",
      labels: ["bug", "frontend"],
      blocked_by: [],
    ),
  ])
}

pub fn decode_issue_with_blockers_test() {
  let json = "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"abc-123\",\"identifier\":\"DAL-42\",\"title\":\"Blocked task\",\"description\":\"\",\"priority\":2,\"state\":{\"name\":\"In Progress\"},\"branchName\":\"\",\"url\":\"\",\"assignee\":null,\"labels\":{\"nodes\":[]},\"relations\":{\"nodes\":[{\"type\":\"blocks\",\"relatedIssue\":{\"id\":\"dep-1\",\"identifier\":\"DAL-10\",\"state\":{\"name\":\"Todo\"}}},{\"type\":\"related\",\"relatedIssue\":{\"id\":\"dep-2\",\"identifier\":\"DAL-11\",\"state\":{\"name\":\"Done\"}}}]}}]}}}"
  let issues = linear.decode_issues(json)
  let assert [issue] = issues
  // Only "blocks" relations become blockers, "related" is ignored
  issue.blocked_by
  |> should.equal([Blocker(id: "dep-1", identifier: "DAL-10", state: "Todo")])
}

pub fn decode_empty_response_test() {
  let json = "{\"data\":{\"issues\":{\"nodes\":[]}}}"
  linear.decode_issues(json) |> should.equal([])
}

pub fn decode_missing_optional_fields_test() {
  // assignee null, description null, branchName null
  let json = "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"x\",\"identifier\":\"DAL-1\",\"title\":\"T\",\"description\":null,\"priority\":0,\"state\":{\"name\":\"Todo\"},\"branchName\":null,\"url\":\"\",\"assignee\":null,\"labels\":{\"nodes\":[]},\"relations\":{\"nodes\":[]}}]}}}"
  let assert [issue] = linear.decode_issues(json)
  issue.assignee_id |> should.equal("")
  issue.description |> should.equal("")
  issue.branch_name |> should.equal("")
}

pub fn decode_malformed_json_returns_empty_test() {
  linear.decode_issues("not json") |> should.equal([])
}

pub fn decode_unexpected_shape_returns_empty_test() {
  linear.decode_issues("{\"data\":{}}") |> should.equal([])
}

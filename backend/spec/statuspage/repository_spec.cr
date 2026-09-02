require "../spec_helper"

private def summary_json : String
  <<-JSON
    {
      "components": [
        { "id": "2", "name": "API", "status": "operational", "group": false },
        { "id": "3", "name": "Websocket", "status": "partial_outage", "group": false }
      ],
      "incidents": [],
      "status": { "indicator": "minor", "description": "Partially Degraded Service" }
    }
    JSON
end

private def repository(page_url : String) : Statuspage::Repository
  Statuspage::Repository.new(
    service_id: "vrchat",
    display_name: "VRChat",
    page_url: page_url,
    component_names: ["API", "Websocket"],
  )
end

describe Statuspage::Repository do
  it "is an official source" do
    repository("https://status.vrchat.com").source_kind.should eq Status::SourceKind::Official
  end

  it "asks the summary endpoint of the page" do
    repository("https://status.vrchat.com").summary_url
      .should eq "https://status.vrchat.com/api/v2/summary.json"
  end

  it "turns the response into an observation" do
    requests = [] of HTTP::Headers
    paths = [] of String

    handler = ->(context : HTTP::Server::Context) do
      requests << context.request.headers.dup
      paths << context.request.path
      context.response.content_type = "application/json"
      context.response.print summary_json
      nil
    end

    with_stub_server(handler) do |page_url|
      observation = repository(page_url).observe

      observation.outcome.should eq Status::Outcome::Success
      observation.service_id.should eq "vrchat"
      observation.level.should eq Status::Level::Degraded
      observation.note.should eq "Websocket: Partial Outage"
      components = observation.components || [] of Status::Component
      components.map(&.name).should eq ["API", "Websocket"]
      observation.latency.should_not be_nil
    end

    paths.should eq ["/api/v2/summary.json"]
    requests.first["User-Agent"].should eq Upstream::USER_AGENT
  end

  it "asks again with the ETag and keeps the last content on 304" do
    etags = [] of String?

    handler = ->(context : HTTP::Server::Context) do
      etags << context.request.headers["If-None-Match"]?
      context.response.headers["ETag"] = %("v1")

      if etags.size == 1
        context.response.content_type = "application/json"
        context.response.print summary_json
      else
        context.response.status = HTTP::Status::NOT_MODIFIED
      end

      nil
    end

    with_stub_server(handler) do |page_url|
      source = repository(page_url)
      source.observe

      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.note.should eq "Websocket: Partial Outage"
    end

    etags.should eq [nil, %("v1")]
  end

  it "fails without raising when the upstream answers with an error" do
    handler = ->(context : HTTP::Server::Context) do
      context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
      nil
    end

    with_stub_server(handler) do |page_url|
      observation = repository(page_url).observe

      observation.outcome.should eq Status::Outcome::Failure
      observation.level.should be_nil
      observation.note.should eq "HTTP 500"
    end
  end

  it "fails without raising when the body is not the JSON it expects" do
    handler = ->(context : HTTP::Server::Context) do
      context.response.content_type = "application/json"
      context.response.print "<html>maintenance</html>"
      nil
    end

    with_stub_server(handler) do |page_url|
      repository(page_url).observe.outcome.should eq Status::Outcome::Failure
    end
  end

  it "fails without raising when nobody answers" do
    observation = repository("http://127.0.0.1:#{unused_port}").observe

    observation.outcome.should eq Status::Outcome::Failure
    observation.note.should_not eq ""
  end
end

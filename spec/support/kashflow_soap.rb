# frozen_string_literal: true

module KashflowSoap
  WSDL_URL = "https://securedwebapp.com/api/service.asmx?WSDL"
  ENDPOINT = "https://securedwebapp.com/api/service.asmx"

  ##
  # Stubs the WSDL fetch with the vendored copy so no spec reaches the network.
  #
  # @return [void]
  #
  def stub_kashflow_wsdl
    stub_request(:get, WSDL_URL).to_return(
      status: 200,
      body: kashflow_wsdl_path.read,
      headers: {"Content-Type" => "text/xml"}
    )
  end

  ##
  # Stubs a SOAP operation with a canned response body.
  #
  # @param body [String] the inner XML of the SOAP body
  # @param status [Integer] HTTP status to return
  # @return [void]
  #
  def stub_kashflow_call(body, status: 200)
    stub_request(:post, ENDPOINT).to_return(
      status: status,
      body: <<~XML,
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>#{body}</soap:Body>
        </soap:Envelope>
      XML
      headers: {"Content-Type" => "text/xml; charset=utf-8"}
    )
  end

  ##
  # Stubs a single SOAP operation, matched on the operation element in the
  # request body. Needed wherever one public method makes more than one call
  # (the customer upsert does a `GetCustomer` then an `InsertCustomer` or
  # `UpdateCustomer`), since {#stub_kashflow_call} answers every POST to the
  # endpoint identically and so cannot distinguish them.
  #
  # @param operation [String] the operation element name, e.g. "GetCustomer"
  # @param body [String] the inner XML of the SOAP body to return
  # @param status [Integer] HTTP status to return
  # @return [WebMock::RequestStub]
  #
  def stub_kashflow_operation(operation, body, status: 200)
    stub_request(:post, ENDPOINT)
      .with(body: /<tns:#{Regexp.escape(operation)}>/)
      .to_return(
        status: status,
        body: <<~XML,
          <?xml version="1.0" encoding="utf-8"?>
          <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
            <soap:Body>#{body}</soap:Body>
          </soap:Envelope>
        XML
        headers: {"Content-Type" => "text/xml; charset=utf-8"}
      )
  end

  private

  ##
  # @return [Pathname] path to the vendored WSDL, resolved relative to the gem root
  #
  def kashflow_wsdl_path
    Pathname.new(File.expand_path("../../docs/kashflow-service.wsdl", __dir__))
  end
end

RSpec.configure { |config| config.include KashflowSoap }

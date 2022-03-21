import Foundation
import Combine

/// Network manager for making API calls.
///
/// NetworkManager will be your app's main point of contact with the networking layer.
/// You are strongly discouraged from declaring an instance as a singleton.
/// Instead we recommend that you use dependency injection to pass a NetworkManager instance
/// to the places in your code where network calls need to be made (Hint: not from your Views, please!)
/// NetworkManager is designed to be highly configurable and extendable. This configuration takes place
/// via the NetworkManagerConfiguration object.
open class NetworkManager: NSObject {
    
    private var configuration: NetworkManagerConfiguration!

    /// File upload progress
    private let fileUpload = FileUploadProgress()
    
    /// File download progress
    private let fileDownload = FileDownloadProgress()

    /// Multicast session delegates
    internal private(set) var sessionDelegates = MulticastDelegate<URLSessionDelegate>()
    
    /// Initializes a network manager in an unconfigured state
    public override init() { }

    deinit {
        sessionDelegates.removeDelegates()
    }

    /// Configure the network manager. This must be called once prior to calling `submit` or `submitDownload`.
    /// It may be called multiple times, but should only be done if the configuration has changed.
    /// - Parameter configuration: the configuration to use
    public func configure(with configuration: NetworkManagerConfiguration) {
        var cached = configuration
        if cached.sessionDelegate == nil {
            // NetworkManager sets itself as session delegate (default behavior) if no delegate is specified
            cached.sessionDelegate = self
        }
        self.configuration = cached
        // configure the session on the network engine
        configuration.networkEngine.configure(with: cached.engineConfiguration)
        
        // Add fileUpload & fileDownload to the multicast sessionDelegates
        add(sessionDelegate: fileUpload)
        add(sessionDelegate: fileDownload)
    }
    
    /// Submit a network request.
    ///
    /// Immediately throws an error if the engine has not been configured.
    /// - Parameters:
    ///   - request: the network request to submit
    ///   - completion: the expected business object upon success, otherwise an error upon failure
    /// - Returns: a cancelable task if one was able to be created, otherwise nil if no task was issued
    @discardableResult open func submit<Response: Decodable>(
        _ request: NetworkRequest,
        completion: @escaping APICompletion<Response>
    ) -> Cancelable? {
        
        do {
            let url = try URLBuilder().url(for: request, configuration: configuration)
            let urlRequest = try buildUrlRequest(for: url, request: request)
            let factory = request.parserFactory ?? configuration.parserFactory

            print("\(request: urlRequest)")
            
            return try configuration.networkEngine.submit(urlRequest) { [weak self] data, response, error in
                self?.processTaskResult(
                    data: data,
                    response: response,
                    error: error,
                    responseType: request.responseType,
                    parser: factory,
                    completion: completion
                )
            }
        } catch {
            completion(.failure(error))
            return nil
        }
    }
    
    /// Submit a background download network request.
    ///
    /// Immediately fails and returns nil if the engine has not been configured.
    /// - Parameters:
    ///     - request: the download network request to submit
    ///     - progress: progress handler (will be called back on main thread)
    /// - Returns: a cancelable download task if one was able to be created, otherwise nil if no task was issued
    @discardableResult open func submitBackgroundDownload(
        _ request: NetworkRequest,
        progress: ProgressHandler? = nil
    ) -> Cancelable? {
        
        guard let url = try? URLBuilder().url(for: request, configuration: configuration),
              let urlRequest = try? buildUrlRequest(for: url, request: request) else { return nil }

        print("\(request: urlRequest)")

        let task = try? configuration?.networkEngine.submitBackgroundDownload(urlRequest)
        fileDownload.register(task, progress: progress)
        return task
    }
    
    /// Submit a background Upload network request.
    ///
    /// Immediately fails and returns nil if the engine has not been configured.
    /// - Parameters:
    ///     - request: the upload network request to submit
    ///     - progress: progress handler (will be called back on main thread)
    /// - Returns: a cancelable upload task if one was able to be created, otherwise nil if no task was issued
    @discardableResult open func submitBackgroundUpload(
        _ request: NetworkRequest,
        progress: ProgressHandler? = nil
    ) -> Cancelable? {

        guard let url = try? URLBuilder().url(for: request, configuration: configuration),
              let urlRequest = try? buildUrlRequest(for: url, request: request) else { return nil }

        print("\(request: urlRequest)")
        
        // write the data to a temporary local file
        guard let localURL = try? urlRequest.writeDataToFile() else { return nil }

        defer {
            // delete the temporary local file
            try? FileManager.default.removeItem(at: localURL)
        }

        // creating the upload task copies the file
        let task = try? configuration?.networkEngine.submitBackgroundUpload(urlRequest, fileUrl: localURL)
        fileUpload.register(task, progress: progress)
        return task
    }
    
    /// Adds a session delegate observer
    /// - Parameter delegate: URL session delegate to add
    public func add(sessionDelegate delegate: URLSessionDelegate) {
        sessionDelegates.addDelegate(delegate)
    }
    
    /// Removes a session delegate observer
    /// - Parameter delegate: URL session delegate to remove
    public func remove(sessionDelegate delegate: URLSessionDelegate) {
        sessionDelegates.removeDelegate(delegate)
    }
}

private extension NetworkManager {
    
    func buildUrlRequest(for url: URL, request: NetworkRequest) throws -> URLRequest {

        var urlRequest = URLRequest(url: url)
        
        urlRequest.httpMethod = request.method.rawValue
        
        if let multipartRequest = request as? MultipartRequest {
            urlRequest.addValue(multipartRequest.multipart.boundary, forHTTPHeaderField: "Boundary")
        }
        
        // Set the request body (if any)
        if let body = request.body {
            let factory = request.parserFactory ?? configuration.parserFactory
            let encoder = factory.encoder(for: request.requestType)
            
            do {
                urlRequest.httpBody = try body.body(encoder: encoder)
            } catch {
                throw NetworkError.serialization(error)
            }
        }
        
        // set request content type
        if let contentType = request.requestType.value {
            urlRequest.addValue(contentType, forHTTPHeaderField: RequestContentType.field)
        }
        
        // add additional headers (if any)
        request.headers?.forEach {
            urlRequest.addValue($0.value, forHTTPHeaderField: $0.key)
        }
        
        return urlRequest
    }

    func processTaskResult<T: Decodable>(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        responseType: ResponseContentType,
        parser factory: DataParserFactory,
        completion: @escaping APICompletion<T>
    ) {
        let result: Result<T, Error>

        defer {
            // callback to completion handler on main thread
            DispatchQueue.main.async {
                completion(result)
            }
        }

        if let error = error {
            result = .failure(mapError(error))
            return
        }

        do {
            let object: T = try processTaskResult(
                data: data,
                response: response,
                responseType: responseType,
                parser: factory
            )
            result = .success(object)
        } catch {
            result = .failure(error)
        }
    }

    func mapError(_ error: Error) -> Error {
        switch (error.code, error.domain) {
        case (NSURLErrorSecureConnectionFailed, NSURLErrorDomain):
            return NetworkError.invalidSSL(error)
        case (NSURLErrorCannotFindHost, NSURLErrorDomain),
            (NSURLErrorCannotConnectToHost, NSURLErrorDomain),
            (NSURLErrorNetworkConnectionLost, NSURLErrorDomain),
            (NSURLErrorNotConnectedToInternet, NSURLErrorDomain),
            (NSURLErrorDNSLookupFailed, NSURLErrorDomain):
            return NetworkError.noInternet(error)
        default:
            return error
        }
    }

    func processTaskResult<T: Decodable>(
        data: Data?,
        response: URLResponse?,
        responseType: ResponseContentType,
        parser factory: DataParserFactory
    ) throws -> T {
        guard let response = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        switch response.statusCode {
        case 200..<300:
            return try parse(data: data, responseType: responseType, parser: factory)
        case 401:
            throw NetworkError.unauthenticated
        default:
            throw HttpError(response: response, data: data)
        }
    }

    func parse<Response: Decodable>(
        data: Data?,
        responseType: ResponseContentType,
        parser: DataParserFactory
    ) throws -> Response {
        guard let data = data else {
            throw NetworkError.noData
        }

        let decoder = parser.decoder(for: responseType)

        switch responseType {
        case .none:
            if let response = EmptyNetworkResponse() as? Response {
                return response
            } else {
                // We received a response when we were not expecting one
                throw NetworkError.unexpectedResponse(type: responseType)
            }
        case .binary:
            if let response = data as? Response {
                // return binary Data directly
                return response
            }

            // otherwise we try to decode it
            fallthrough
        case .JSON:
            print("\(json: data)")

            guard let decoder = decoder else {
                throw NetworkError.noDecoder
            }

            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw NetworkError.deserialization(error)
            }
        }
    }
}

// MARK: Combine Implemnatation

extension NetworkManager {

    /// Submit a network request using Combine.
    ///
    /// Immediately throws an error if the engine has not been configured.
    /// - Parameter request: the network request to submit
    /// - Returns: a publisher that delivers the results of performing the request.
    open func submit<Response: Decodable>(
        _ request: NetworkRequest
    ) -> AnyPublisher<Response, Error> {

        do {
            let url = try URLBuilder().url(for: request, configuration: configuration)
            let urlRequest = try buildUrlRequest(for: url, request: request)
            let factory = request.parserFactory ?? configuration.parserFactory

            print("\(request: urlRequest)")

            return try configuration.networkEngine.submit(urlRequest)
                .tryMap { data, response -> Response in
                    try self.processTaskResult(
                        data: data,
                        response: response,
                        responseType: request.responseType,
                        parser: factory
                    )
                }
                .mapError { self.mapError($0) }
                .receive(on: DispatchQueue.main)
                .eraseToAnyPublisher()
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
    }
}

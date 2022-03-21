import Foundation
import Hermes
import Apollo
import Metis

protocol ProductListViewModelOutput: AnyObject {
    func productListFetchSuccess()
    func productListFetchFailed(error: Error)
    func productDeleteSuccess(index: Int)
    func productDeleteFailed(error: Error)
}

protocol ProductListPresentation: AnyObject {
    var numberOfListItems: Int { get }
    func listItemFor(index: Int) -> ListItem?
}

extension ProductModel: ListItem {
    
    var id: String { productId }
    
    var name: String { productName }
    
    var price: String { productPrice }
    
    var description: String? { productDescription }
    
    var image: String? { productImage }
    
    var categories: [String]? { productCategories }
}

class ProductListViewModel {
    
    private let networkManager: NetworkManager
    private let persistenceManager: PersistenceManager
    private let analytics: AnalyticsEngine

    weak var output: ProductListViewModelOutput?
    private var products: [ProductModel] = []
    
    // We inject the network manager, the persistence manager, and the analytics engine
    // instead of referring to a singleton.
    // This facilitates not just unit testing but also
    // being able to swap components.
    init(networkManager: NetworkManager, persistenceManager: PersistenceManager, analytics: AnalyticsEngine) {
        self.networkManager = networkManager
        self.persistenceManager = persistenceManager
        self.analytics = analytics
    }
}

extension ProductListViewModel {

    func fetchProductList() {
        fetchProductListFromRemote { [weak self] result in
            guard let self = self else { return }
            
            do {
                let productList = try result.get()
                try self.cacheProducts(productList)
                self.products = try self.loadProductsFromCache()
                // Inform client fetch products success (network + sucess).
                self.output?.productListFetchSuccess()
                // Track success (network + cache).
                self.track(Analytics.productListSuccessEvent(for: productList))
            } catch {
                // Inform client fetch products failed (network or cache).
                self.output?.productListFetchFailed(error: error)
                // Track failure (network or cache).
                self.track(Analytics.productListFailureEvent(for: error))
            }
        }
    }
    
    func fetchProductListFromRemote(completion: @escaping (Result<[ProductModel], Error>) -> Void) {
        // Create network request.
        let request = ProductListRequest()
        // Track it to analytics.
        track(Analytics.productListRequestEvent(for: request))
        
        // Issue network request.
        networkManager.submit(request, completion: completion)
    }
}

extension ProductListViewModel {
    
    func cacheProducts(_ productList: [ProductModel]) throws {
        try persistenceManager.save(
            entity: ProductRecord.self,
            models: productList,
            shouldOverwrite: true
        )
    }
    
    func loadProductsFromCache() throws -> [ProductModel] {
        let results = try persistenceManager.fetchModels(entity: ProductRecord.self, uids: nil)
        return results.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }
}

extension ProductListViewModel {

    func deleteProductFromList(index: Int) {
        guard let productId = listItemFor(index: index)?.id else { return }
        
        deleteProductFromRemote(productId: productId) { [weak self] result in
            guard let self = self else { return }

            do {
                // extract the product from the response
                let product = try result.get()
                // delete it from local storage
                self.products = try self.deleteFromCache(product)
                // handle success
                self.output?.productDeleteSuccess(index: index)
                // track success
                self.track(Analytics.deleteProductSuccessEvent(for: product))
            } catch {
                // handle failure
                self.output?.productDeleteFailed(error: error)
                // track failure
                self.track(Analytics.deleteProductFailureEvent(for: error))
            }
        }
    }

    func deleteProductFromRemote(productId: String, completion: @escaping (Result<ProductModel, Error>) -> Void) {
        let request = ProductDeleteRequest(productID: productId)
        track(Analytics.deleteProductRequestEvent(for: request))
        
        networkManager.submit(request, completion: completion)
    }
    
    func deleteFromCache(_ product: ProductModel) throws -> [ProductModel] {
        try persistenceManager.deleteModel(entity: ProductRecord.self, model: product)
        return try loadProductsFromCache()
    }
}

extension ProductListViewModel: ProductListPresentation {
    
    var numberOfListItems: Int { products.count }
    
    func listItemFor(index: Int) -> ListItem? {
        guard index < products.count else { return nil }
        return products[index]
    }
}

// MARK: - Analytics

extension ProductListViewModel {

    func track(_ event: AnalyticsEvent) {
        analytics.track(event: event)
    }
}

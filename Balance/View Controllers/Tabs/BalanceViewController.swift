import Foundation
import PagingKit
import SnapKit

class BalanceViewController: UIViewController, PagingMenuViewControllerDataSource, PagingContentViewControllerDataSource, PagingMenuViewControllerDelegate, PagingContentViewControllerDelegate {
    struct Notifications {
        static let startedLoadingBalances = Notification.Name("BalanceViewController.startedLoadingBalances")
        static let finishedLoadingBalances = Notification.Name("BalanceViewController.finishedLoadingBalances")
    }

    private var menuViewController = PagingMenuViewController()
    private var contentViewController = PagingContentViewController()

    private let menuBackgroundView: UIView = {
        let menuBackgroundView = UIView()
        menuBackgroundView.backgroundColor = .white
        return menuBackgroundView
    }()

    private let loadingSpinner: UIActivityIndicatorView = {
        let loadingSpinner = UIActivityIndicatorView(style: .whiteLarge)
        loadingSpinner.color = .gray
        loadingSpinner.hidesWhenStopped = true
        loadingSpinner.startAnimating()
        return loadingSpinner
    }()

    private var isLoading = false
    private var isFirstLoad = true
    private var lastLoadTimestamp = 0.0

    private var contentViewControllers = [BalanceContentViewController]()
    private var ethereumWallets = [EthereumWallet]()
    private var aggregatedEthereumWallet: EthereumWallet?
    private var refresh: UIRefreshControl?

    // MARK: - View Lifecycle -

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor(hexString: "#fbfbfb")

        menuBackgroundView.isHidden = true
        view.addSubview(menuBackgroundView)
        menuBackgroundView.snp.makeConstraints { make in
            make.height.equalTo(44)
            make.top.equalTo(view.snp.topMargin)
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview()
        }

        // Setup first load spinner
        view.addSubview(loadingSpinner)
        loadingSpinner.snp.makeConstraints { make in
            make.top.equalTo(menuBackgroundView.snp.bottom).offset(10)
            make.centerX.equalToSuperview()
        }

        loadData()

        NotificationCenter.default.addObserver(self, selector: #selector(walletAdded), name: CoreDataHelper.Notifications.ethereumWalletAdded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(walletChanged), name: CoreDataHelper.Notifications.ethereumWalletChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(walletRemoved), name: CoreDataHelper.Notifications.ethereumWalletRemoved, object: nil)
    }

    private func addPagingController() {
        menuBackgroundView.isHidden = false

        var nextTopPoint = 0
        // Setup menu
        if shouldShowMenu() {
            let menuHeight = 44
            menuViewController = PagingMenuViewController()
            menuViewController.delegate = self
            menuViewController.dataSource = self
            menuViewController.register(type: MenuViewTitleCell.self, forCellWithReuseIdentifier: "MenuViewTitleCell")
            menuViewController.registerFocusView(view: MenuUnderlineView())
            addChild(menuViewController)
            view.addSubview(menuViewController.view)
            menuViewController.didMove(toParent: self)
            menuViewController.view.snp.makeConstraints { make in
                make.height.equalTo(menuHeight)
                make.top.equalTo(view.snp.topMargin)
                make.leading.equalToSuperview()
                make.trailing.equalToSuperview()
            }
            nextTopPoint = menuHeight
        }

        // Setup content
        contentViewController = PagingContentViewController()
        contentViewController.delegate = self
        contentViewController.dataSource = self
        addChild(contentViewController)
        view.addSubview(contentViewController.view)
        contentViewController.didMove(toParent: self)
        contentViewController.view.snp.makeConstraints { make in
            make.top.equalTo(nextTopPoint)
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview()
            make.bottom.equalToSuperview()
        }
    }

    private func removePagingController() {
        menuBackgroundView.isHidden = true
        menuViewController.view.removeFromSuperview()
        menuViewController.removeFromParent()
        contentViewController.view.removeFromSuperview()
        contentViewController.removeFromParent()
        contentViewControllers.removeAll()
    }

    // MARK: - Data Loading -

    private func updateContentControllers(countChanged: Bool) {
        if countChanged {
            removePagingController()
        }

        if contentViewControllers.isEmpty {
            if let aggregatedEthereumWallet = aggregatedEthereumWallet {
                let balanceContentViewController = BalanceContentViewController()
                balanceContentViewController.ethereumWallet = aggregatedEthereumWallet
                balanceContentViewController.title = "All Wallets"
                balanceContentViewController.refreshBlock = {
                    self.loadData()
                    self.refresh = balanceContentViewController.refreshControl
                }
                contentViewControllers.append(balanceContentViewController)
            }

            for ethereumWallet in ethereumWallets {
                let balanceContentViewController = BalanceContentViewController()
                balanceContentViewController.ethereumWallet = ethereumWallet
                balanceContentViewController.title = ethereumWallet.pagingTabTitle()
                balanceContentViewController.refreshBlock = {
                    self.loadData()
                    self.refresh = balanceContentViewController.refreshControl
                }
                contentViewControllers.append(balanceContentViewController)
            }

            addPagingController()
        } else {
            var offset = 0
            if let aggregatedEthereumWallet = aggregatedEthereumWallet {
                contentViewControllers[0].ethereumWallet = aggregatedEthereumWallet
                offset = 1
            }
            for (index, ethereumWallet) in ethereumWallets.enumerated() {
                contentViewControllers[index + offset].ethereumWallet = ethereumWallet
                contentViewControllers[index + offset].title = ethereumWallet.pagingTabTitle()
            }
        }

        menuViewController.reloadData()
        contentViewController.reloadData()
        for contentViewController in contentViewControllers {
            contentViewController.reloadData()
        }

        NotificationCenter.default.post(name: Notifications.finishedLoadingBalances, object: nil)

        // Fix for menu not showing up on first load
        menuViewController.menuView.contentOffset.y = 0
    }

    @objc func loadData() {
        NotificationCenter.default.post(name: Notifications.startedLoadingBalances, object: nil)

        guard CoreDataHelper.ethereumWalletCount() > 0 else {
            ethereumWallets = [EthereumWallet]()
            aggregatedEthereumWallet = nil
            contentViewControllers = [BalanceContentViewController]()
            updateContentControllers(countChanged: false)
            return
        }

        if isLoading {
            // Wait a bit and try again
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(loadData), object: nil)
            perform(#selector(loadData), with: nil, afterDelay: 0.5)
            return
        }

        let delay = 0.25
        let secondsSinceLastLoad = NSDate().timeIntervalSince1970 - lastLoadTimestamp
        if secondsSinceLastLoad < delay {
            // Wait a few seconds and try again
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(loadData), object: nil)
            perform(#selector(loadData), with: nil, afterDelay: delay - secondsSinceLastLoad)
            return
        }

        isLoading = true
        DispatchQueue.utility.async {
            // On first load, only load the first (eventually primary) wallet, then load again
            var newEthereumWallets = [EthereumWallet]()
            var newAggregatedEthereumWallet: EthereumWallet?
            if self.isFirstLoad, let primaryWallet = CoreDataHelper.loadPrimaryEthereumWallet() {
                newEthereumWallets = [primaryWallet]
            } else {
                newEthereumWallets = CoreDataHelper.loadAllEthereumWallets()
            }

            // Extra check in case of race condition
            guard !newEthereumWallets.isEmpty else {
                self.ethereumWallets = [EthereumWallet]()
                self.aggregatedEthereumWallet = nil
                self.contentViewControllers = [BalanceContentViewController]()
                self.isLoading = false
                DispatchQueue.main.async {
                    self.updateContentControllers(countChanged: false)
                }
                return
            }

            let dispatchGroup = DispatchGroup()

            // Load balances and ETH price first
            dispatchGroup.enter()

            AmberdataAPI.loadWalletBalances(newEthereumWallets) { wallets in
                newEthereumWallets = wallets
                dispatchGroup.leave()
            }

            // Load CDPs
            dispatchGroup.enter()
            var newEthereumWalletsCDPs = [EthereumWallet]()
            MakerToolsAPI.loadEthereumWalletCDPs(newEthereumWallets) { wallets in
                newEthereumWalletsCDPs = wallets
                dispatchGroup.leave()
            }

            // Wait for results
            dispatchGroup.wait()

            // Copy the CDPs into the main wallet array
            // NOTE: This is a little clunky but it allows us to load both APIs at once
            for index in 0 ..< newEthereumWallets.count {
                newEthereumWallets[index].CDPs = newEthereumWalletsCDPs[index].CDPs
            }

            // Aggregate the balances
            if newEthereumWallets.count > 1 {
                newAggregatedEthereumWallet = EthereumWallet.aggregated(wallets: newEthereumWallets)
            }

            // Store the results and reload the table
            DispatchQueue.main.async {
                let countChanged = newEthereumWallets.count != self.ethereumWallets.count
                self.ethereumWallets = newEthereumWallets
                self.aggregatedEthereumWallet = newAggregatedEthereumWallet
                self.lastLoadTimestamp = Date().timeIntervalSince1970
                self.isLoading = false
                self.loadingSpinner.stopAnimating()
                self.updateContentControllers(countChanged: countChanged)
                self.refresh?.endRefreshing()

                // Now that we've loaded the first wallet, load the rest if there are more than one
                if self.isFirstLoad {
                    self.isFirstLoad = false

                    if CoreDataHelper.ethereumWalletCount() > 1 {
                        // Perform after delay to allow the loading spinner to animate away first
                        self.perform(#selector(self.loadData), with: nil, afterDelay: 0.5)
                    }
                }
            }
        }
    }

    @objc private func walletAdded() {
        walletsChanged()
    }

    @objc private func walletChanged() {
        walletsChanged()
    }

    @objc private func walletRemoved() {
        walletsChanged()
    }

    private func walletsChanged() {
        removePagingController()
        loadingSpinner.startAnimating()
        loadData()
    }

    // MARK: - PagingKit -

    func menuViewController(viewController: PagingMenuViewController, cellForItemAt index: Int) -> PagingMenuViewCell {
        let cell = viewController.dequeueReusableCell(withReuseIdentifier: "MenuViewTitleCell", for: index) as! MenuViewTitleCell
        cell.titleLabel.text = contentViewControllers[index].title
        return cell
    }

    private static let sizingCell = MenuViewTitleCell()
    func menuViewController(viewController: PagingMenuViewController, widthForItemAt index: Int) -> CGFloat {
        BalanceViewController.sizingCell.titleLabel.text = contentViewControllers[index].title
        var referenceSize = UIView.layoutFittingCompressedSize
        referenceSize.height = viewController.view.bounds.height
        let size = BalanceViewController.sizingCell.systemLayoutSizeFitting(referenceSize)
        return size.width
    }

    var insets: UIEdgeInsets {
        return view.safeAreaInsets
    }

    func shouldShowMenu() -> Bool {
        return contentViewControllers.count > 1
    }

    func numberOfItemsForMenuViewController(viewController _: PagingMenuViewController) -> Int {
        return contentViewControllers.count
    }

    func numberOfItemsForContentViewController(viewController _: PagingContentViewController) -> Int {
        return contentViewControllers.count
    }

    func contentViewController(viewController _: PagingContentViewController, viewControllerAt index: Int) -> UIViewController {
        return contentViewControllers[index]
    }

    func menuViewController(viewController _: PagingMenuViewController, didSelect page: Int, previousPage _: Int) {
        contentViewController.scroll(to: page, animated: true)
    }

    func contentViewController(viewController _: PagingContentViewController, didManualScrollOn index: Int, percent: CGFloat) {
        menuViewController.scroll(index: index, percent: percent, animated: false)
    }
}

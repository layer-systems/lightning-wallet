import SwiftUI
import PhoenixShared
import os.log

#if DEBUG && true
fileprivate var log = Logger(
	subsystem: Bundle.main.bundleIdentifier!,
	category: "PaymentCell"
)
#else
fileprivate var log = Logger(OSLog.disabled)
#endif


struct PaymentCell : View {

	static private let appDelegate = AppDelegate.get()
	static private let phoenixBusiness = appDelegate.business
	static private let paymentsManager = phoenixBusiness.paymentsManager
	
	private let paymentsManager = PaymentCell.paymentsManager
	
	let row: WalletPaymentOrderRow
	let didAppearCallback: ((WalletPaymentOrderRow) -> Void)?
	
	@State var fetched: WalletPaymentInfo?
	@State var fetchedIsStale: Bool
	
	@ScaledMetric var textScaling: CGFloat = 100
	
	@EnvironmentObject var currencyPrefs: CurrencyPrefs

	init(
		row: WalletPaymentOrderRow,
		didAppearCallback: ((WalletPaymentOrderRow) -> Void)?
	) {
		self.row = row
		self.didAppearCallback = didAppearCallback
		
		let options = WalletPaymentFetchOptions.companion.Descriptions
		var result = paymentsManager.fetcher.getCachedPayment(row: row, options: options)
		if let _ = result {
			
			self._fetched = State(initialValue: result)
			self._fetchedIsStale = State(initialValue: false)
		} else {
			
			result = paymentsManager.fetcher.getCachedStalePayment(row: row, options: options)
			
			self._fetched = State(initialValue: result)
			self._fetchedIsStale = State(initialValue: true)
		}
	}
	
	@ViewBuilder
	var body: some View {
		
		HStack {
			if let payment = fetched?.payment {
				
				switch payment.state() {
					case .success:
						Image("payment_holder_def_success")
							.foregroundColor(Color.accentColor)
							.padding(4)
							.background(
								RoundedRectangle(cornerRadius: .infinity)
									.fill(Color.appAccent)
							)
					case .pending:
						Image("payment_holder_def_pending")
							.foregroundColor(Color.appAccent)
							.padding(4)
					case .failure:
						Image("payment_holder_def_failed")
							.foregroundColor(Color.appAccent)
							.padding(4)
					default:
						Image(systemName: "doc.text.magnifyingglass")
							.padding(4)
				}
			} else {
				
				Image(systemName: "doc.text.magnifyingglass")
					.padding(4)
			}

			VStack(alignment: .leading) {
				Text(paymentDescription())
					.lineLimit(1)
					.truncationMode(.tail)
					.foregroundColor(.primaryForeground)

				Text(paymentTimestamp())
					.font(.caption)
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding([.leading, .trailing], 6)

			HStack(alignment: VerticalAlignment.firstTextBaseline, spacing: 0) {

				let (amount, isFailure, isOutgoing) = paymentAmountInfo()

				if currencyPrefs.hideAmountsOnHomeScreen {
					
					// Do not display any indication as to whether payment in incoming or outgoing
					Text(verbatim: amount.digits)
						.foregroundColor(.primary)
					
				} else {
					
					let color: Color = isFailure ? .secondary : (isOutgoing ? .appNegative : .appPositive)
					HStack(alignment: VerticalAlignment.firstTextBaseline, spacing: 0) {
					
						Text(verbatim: isOutgoing ? "-" : "+")
							.foregroundColor(color)
							.padding(.trailing, 1)
						
						Text(verbatim: amount.digits)
							.foregroundColor(color)
					}
					.environment(\.layoutDirection, .leftToRight) // issue #237
					
					Text(verbatim: " ") // separate for RTL languages
						.font(.caption)
						.foregroundColor(.gray)
					Text(verbatim: amount.type)
						.font(.caption)
						.foregroundColor(.gray)
				}
			}
		}
		.padding([.top, .bottom], 14)
		.padding([.leading, .trailing], 12)
		.onAppear {
			onAppear()
		}
	}

	func paymentDescription() -> String {

		if let fetched = fetched {
			return fetched.paymentDescription() ?? NSLocalizedString("No description", comment: "placeholder text")
		} else {
			return ""
		}
	}
	
	func paymentTimestamp() -> String {

		guard let payment = fetched?.payment else {
			return ""
		}
		let timestamp = payment.completedAt()
		guard timestamp > 0 else {
			return NSLocalizedString("pending", comment: "timestamp string for pending transaction")
		}
			
		let date = timestamp.toDate(from: .milliseconds)
		
		let formatter = DateFormatter()
		if textScaling > 100 {
			formatter.dateStyle = .short
		} else {
			formatter.dateStyle = .long
		}
		formatter.timeStyle = .short
		
		return formatter.string(from: date)
	}
	
	func paymentAmountInfo() -> (FormattedAmount, Bool, Bool) {

		if let payment = fetched?.payment {

			let amount = currencyPrefs.hideAmountsOnHomeScreen
				? Utils.hiddenAmount(currencyPrefs)
				: Utils.format(currencyPrefs, msat: payment.amount)

			let isFailure = payment.state() == WalletPaymentState.failure
			let isOutgoing = payment is Lightning_kmpOutgoingPayment

			return (amount, isFailure, isOutgoing)

		} else {
			
			let currency = currencyPrefs.currency
			let amount = FormattedAmount(amount: 0.0, currency: currency, digits: "", decimalSeparator: " ")

			let isFailure = false
			let isOutgoing = true

			return (amount, isFailure, isOutgoing)
		}
	}
	
	func onAppear() -> Void {
		
		if fetched == nil || fetchedIsStale {
			
			let options = WalletPaymentFetchOptions.companion.Descriptions
			paymentsManager.fetcher.getPayment(row: row, options: options) { (result: WalletPaymentInfo?, _) in
				self.fetched = result
			}
		}
		
		if let didAppearCallback = didAppearCallback {
			didAppearCallback(row)
		}
	}
}

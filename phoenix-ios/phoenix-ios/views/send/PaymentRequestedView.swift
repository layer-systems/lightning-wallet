import SwiftUI
import PhoenixShared
import os.log

#if DEBUG && true
fileprivate var log = Logger(
	subsystem: Bundle.main.bundleIdentifier!,
	category: "PaymentRequestedView"
)
#else
fileprivate var log = Logger(OSLog.disabled)
#endif

/// Used after a lnurl-withdraw is completed.
/// 
struct PaymentRequestedView: View {
	
	@ObservedObject var mvi: MVIState<Scan.Model, Scan.Intent>
	
	@Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
	@EnvironmentObject var currencyPrefs: CurrencyPrefs
	
	let lastIncomingPaymentPublisher = AppDelegate.get().business.paymentsManager.lastIncomingPaymentPublisher()
	
	@ViewBuilder
	var body: some View {
		
		ZStack {
			Color.primaryBackground
				.edgesIgnoringSafeArea(.all)
			
			if AppDelegate.showTestnetBackground {
				Image("testnet_bg")
					.resizable(resizingMode: .tile)
					.ignoresSafeArea(.all, edges: .all)
			}
			
			content
		}
		.frame(maxHeight: .infinity)
		.edgesIgnoringSafeArea([.bottom, .leading, .trailing]) // top is nav bar
		.navigationBarTitle(
			NSLocalizedString("Payment Requested", comment: "Navigation bar title"),
			displayMode: .inline
		)
		.onReceive(lastIncomingPaymentPublisher) {
			lastIncomingPaymentChanged($0)
		}
	}
	
	@ViewBuilder
	var content: some View {
		
		VStack(alignment: HorizontalAlignment.center, spacing: 0) {
		
			let host = paymentRequestHost() ?? "🌐"
			Text("Payment requested from \(host)")
				.multilineTextAlignment(.center)
				.font(.title)
			
			let amount = paymentAmount()?.string ?? ""
			Text("You should soon receive a payment for \(amount)")
				.multilineTextAlignment(.center)
				.padding(.vertical, 40)
			
			Button {
				closeButtonTapped()
			} label: {
				HStack(alignment: VerticalAlignment.firstTextBaseline) {
					Image(systemName: "checkmark.circle")
						.renderingMode(.template)
						.imageScale(.medium)
					Text("Close")
				}
				.font(.title3)
				.foregroundColor(Color.white)
				.padding(.top, 4)
				.padding(.bottom, 5)
				.padding([.leading, .trailing], 24)
			}
			.buttonStyle(ScaleButtonStyle(
				cornerRadius: 100,
				backgroundFill: Color.appAccent,
				disabledBackgroundFill: Color(UIColor.systemGray)
			))
		}
		.padding()
	}
	
	func paymentRequestHost() -> String? {
		
		if let model = mvi.model as? Scan.Model_LnurlWithdrawFlow_Receiving {
			
			return model.lnurlWithdraw.lnurl.host
		}
		
		return nil
	}
	
	func paymentAmount() -> FormattedAmount? {
		
		if let model = mvi.model as? Scan.Model_LnurlWithdrawFlow_Receiving {
			
			return Utils.formatBitcoin(msat: model.amount, bitcoinUnit: currencyPrefs.bitcoinUnit)
		}
		
		return nil
	}
	
	func closeButtonTapped() {
		log.trace("closeButtonTapped()")
		
		// Pop self from NavigationStack; Back to HomeView
		presentationMode.wrappedValue.dismiss()
	}
	
	func lastIncomingPaymentChanged(_ lastIncomingPayment: Lightning_kmpIncomingPayment) {
		log.trace("lastIncomingPaymentChanged()")
		
		guard let model = mvi.model as? Scan.Model_LnurlWithdrawFlow_Receiving else {
			return
		}
		
		log.debug("lastIncomingPayment.paymentHash = \(lastIncomingPayment.paymentHash.toHex())")
		
		if lastIncomingPayment.state() == WalletPaymentState.success &&
			lastIncomingPayment.paymentHash.toHex() == model.paymentHash
		{
			presentationMode.wrappedValue.dismiss()
		}
	}
}

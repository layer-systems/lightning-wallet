import Foundation
import PhoenixShared


extension Lightning_kmpWalletPayment {
	
	func paymentType() -> (String, String)? {
		
		// Will be displayed in the UI as:
		//
		// Type : value (explanation)
		//
		// where return value is: (value, explanation)
		
		if let incomingPayment = self as? Lightning_kmpIncomingPayment {
			
			if let _ = incomingPayment.origin.asSwapIn() {
				let val = NSLocalizedString("Swap-In", comment: "Transaction Info: Value")
				let exp = NSLocalizedString("layer 1 -> 2", comment: "Transaction Info: Explanation")
				return (val, exp.lowercased())
			}
			if let _ = incomingPayment.origin.asKeySend() {
				let val = NSLocalizedString("KeySend", comment: "Transaction Info: Value")
				let exp = NSLocalizedString("non-invoice payment", comment: "Transaction Info: Explanation")
				return (val, exp.lowercased())
			}
			
		} else if let outgoingPayment = self as? Lightning_kmpOutgoingPayment {
			
			if let _ = outgoingPayment.details.asSwapOut() {
				let val = NSLocalizedString("Swap-Out", comment: "Transaction Info: Value")
				let exp = NSLocalizedString("layer 2 -> 1", comment: "Transaction Info: Explanation")
				return (val, exp.lowercased())
			}
			if let _ = outgoingPayment.details.asKeySend() {
				let val = NSLocalizedString("KeySend", comment: "Transaction Info: Value")
				let exp = NSLocalizedString("non-invoice payment", comment: "Transaction Info: Explanation")
				return (val, exp.lowercased())
			}
			if let _ = outgoingPayment.details.asChannelClosing() {
				let val = NSLocalizedString("Channel Closing", comment: "Transaction Info: Value")
				let exp = NSLocalizedString("layer 2 -> 1", comment: "Transaction Info: Explanation")
				return (val, exp.lowercased())
			}
		}
		
		return nil
	}
	
	func paymentLink() -> URL? {
		
		var address: String? = nil
		if let incomingPayment = self as? Lightning_kmpIncomingPayment {
		
			if let swapIn = incomingPayment.origin.asSwapIn() {
				address = swapIn.address
			}
			
		} else if let outgoingPayment = self as? Lightning_kmpOutgoingPayment {
		
			if let swapOut = outgoingPayment.details.asSwapOut() {
				address = swapOut.address
			}
		}
		
		if let address = address {
			let str: String
			if AppDelegate.get().business.chain.isTestnet() {
				str = "https://mempool.space/testnet/address/\(address)"
			} else {
				str = "https://mempool.space/address/\(address)"
			}
			return URL(string: str)
		}
		
		return nil
	}
	
	func channelClosing() -> Lightning_kmpOutgoingPayment.DetailsChannelClosing? {
		
		if let outgoingPayment = self as? Lightning_kmpOutgoingPayment {
			if let result = outgoingPayment.details.asChannelClosing() {
				return result
			}
		}
		
		return nil
	}
	
	func standardFees(currencyPrefs: CurrencyPrefs) -> (FormattedAmount, String)? {
		
		if let incomingPayment = self as? Lightning_kmpIncomingPayment {
		
			// An incomingPayment may have fees if a new channel was automatically opened
			if let received = incomingPayment.received {
					
				let msat = received.receivedWith.map { $0.fees.msat }.reduce(0, +)
				if msat > 0 {
					
					let formattedAmt = Utils.format(currencyPrefs, msat: msat, policy: .showMsatsIfNonZero)
					let exp = NSLocalizedString(
						"""
						In order to receive this payment, a new payment channel was opened. \
						This is not always required.
						""",
						comment: "Fees explanation"
					)
					
					return (formattedAmt, exp)
				}
				else {
					// I think it's nice to see "Fees: 0 sat" :)
					
					let formattedAmt = Utils.format(currencyPrefs, msat: 0, policy: .hideMsats)
					let exp = ""
					
					return (formattedAmt, exp)
				}
			}
			
		} else if let outgoingPayment = self as? Lightning_kmpOutgoingPayment {
		
			if let _ = outgoingPayment.status.asFailed() {
				
				// no fees for failed payments
				return nil
				
			} else if let _ = outgoingPayment.status.asOnChain() {
				
				// for on-chain payments, the fees are extracted from the mined transaction(s)
				
				let fees = outgoingPayment.fees
				let formattedAmt = Utils.format(currencyPrefs, msat: fees, policy: .showMsatsIfNonZero)
				
				let txCount = outgoingPayment.closingTxParts().count
				let exp: String
				if txCount == 1 {
					exp = NSLocalizedString(
						"Bitcoin network fees paid for on-chain transaction. Payment required 1 transaction.",
						comment: "Fees explanation"
					)
				} else {
					exp = NSLocalizedString(
						"Bitcoin network fees paid for on-chain transactions. Payment required \(txCount) transactions.",
						comment: "Fees explanation"
					)
				}
				
				return (formattedAmt, exp)
				
			} else if let _ = outgoingPayment.status.asOffChain() {
				
				let msat = outgoingPayment.routingFee.msat // excludes swapOutFee
				if msat == 0 {
					return nil
				}
				
				let formattedAmt = Utils.format(currencyPrefs, msat: msat, policy: .showMsatsIfNonZero)
				
				var parts = 0
				var hops = 0
				for part in outgoingPayment.parts {
					if (part is Lightning_kmpOutgoingPayment.LightningPart) {
						parts += 1
						hops = (part as! Lightning_kmpOutgoingPayment.LightningPart).route.count
					}
				}
				
				let exp: String
				if parts == 1 {
					if hops == 1 {
						exp = NSLocalizedString(
							"Lightning fees for routing the payment. Payment required 1 hop.",
							comment: "Fees explanation"
						)
					} else {
						exp = String(format: NSLocalizedString(
							"Lightning fees for routing the payment. Payment required %d hops.",
							comment: "Fees explanation"),
							hops
						)
					}
					
				} else {
					exp = String(format: NSLocalizedString(
						"Lightning fees for routing the payment. Payment was divided into %d parts, using %d hops.",
						comment: "Fees explanation"),
						parts, hops
					)
				}
				
				return (formattedAmt, exp)
			}
		}
		
		return nil
	}
	
	func swapOutFees(currencyPrefs: CurrencyPrefs) -> (FormattedAmount, String)? {
		
		guard let outgoingPayment = self as? Lightning_kmpOutgoingPayment else {
			return nil
		}
		
		if let _ = outgoingPayment.details.asSwapOut() {
			
			let msat = outgoingPayment.fees.msat - outgoingPayment.routingFee.msat
			let formattedAmt = Utils.format(currencyPrefs, msat: msat, policy: .showMsatsIfNonZero)
			
			let exp = NSLocalizedString(
				"Includes Bitcoin network miner fees, and the fee for the Swap-Out service.",
				comment: "Fees explanation"
			)
			
			return (formattedAmt, exp)
			
		} else {
			
			return nil
		}
	}
	
	/// If the OutgoingPayment succeeded or failed, reports the total elapsed time.
	/// The return value is in number of milliseconds.
	///
	func paymentTimeElapsed() -> Int64? {

		if let outgoingPayment = self as? Lightning_kmpOutgoingPayment {
			
			let started = outgoingPayment.createdAt
			var finished: Int64? = nil
			
			if let failed = outgoingPayment.status.asFailed() {
				finished = failed.completedAt
				
			} else if let succeeded = outgoingPayment.status.asSucceeded() {
				finished = succeeded.completedAt
			}
			
			if let finished = finished, finished > started {
				return finished - started
			}
		}
		
		return nil
	}
	
	func paymentFinalError() -> String? {

		if let outgoingPayment = self as? Lightning_kmpOutgoingPayment {
			
			if let failed = outgoingPayment.status.asFailed() {
				
				return failed.reason.description
			}
		}
		
		return nil
	}
}

extension Lightning_kmpOutgoingPayment {
	
	func closingTxParts() -> [Lightning_kmpOutgoingPayment.ClosingTxPart] {
		
		var closingTxParts = [Lightning_kmpOutgoingPayment.ClosingTxPart]()
		for part in self.parts {
			if let closingTxPart = part as? Lightning_kmpOutgoingPayment.ClosingTxPart {
				closingTxParts.append(closingTxPart)
			}
		}
		
		return closingTxParts
	}
	
	func claimedOnChain() -> Bitcoin_kmpSatoshi {
		
		var sat: Int64 = 0
		for part in closingTxParts() {
			sat += part.claimed.sat
		}
		
		return Bitcoin_kmpSatoshi(sat: sat)
	}
}

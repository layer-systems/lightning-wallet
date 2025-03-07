package fr.acinq.phoenix.db.cloud

import fr.acinq.lightning.utils.currentTimestampMillis
import fr.acinq.phoenix.db.payments.LNUrlBase
import fr.acinq.phoenix.db.payments.LNUrlMetadata
import fr.acinq.phoenix.db.payments.LNUrlSuccessAction
import fr.acinq.phoenix.db.payments.WalletPaymentMetadataRow
import kotlinx.serialization.*
import kotlinx.serialization.cbor.ByteString
import kotlinx.serialization.cbor.Cbor

enum class CloudAssetVersion(val value: Int) {
    // Initial version
    V0(0),
    // V1:
    // - added `original_fiat`
    V1(1)
    // Future versions go here
}

// Upgrade notes:
// If needed in the future, you can use code like this to extract only the version:
//
// data class CloudAssetVersion(
//    @SerialName("v")
//    val version: Int
// )
// val version: CloudAssetVersion = try {
//    Cbor {
//       ignoreUnknownKeys = true
//    }.decodeFromByteArray(blob)
// } catch (e: Throwable) {
//    return null
// }

@Serializable
@OptIn(ExperimentalSerializationApi::class)
data class CloudAsset(
    @SerialName("v")
    val version: Int,
    val lnurl_base: LNUrlBaseWrapper?,
    val lnurl_metadata: LNUrlMetadataWrapper?,
    val lnurl_successAction: LNUrlSuccessActionWrapper?,
    val lnurl_description: String?,
    val user_description: String?,
    val user_notes: String?,
    val original_fiat: OriginalFiatWrapper? = null // added in V1
) {
    @Serializable
    @OptIn(ExperimentalSerializationApi::class)
    data class LNUrlBaseWrapper(
        val type: String,
        @ByteString
        val blob: ByteArray
    ) {
        var typeVersion = LNUrlBase.TypeVersion.valueOf(type)
    }

    @Serializable
    @OptIn(ExperimentalSerializationApi::class)
    data class LNUrlMetadataWrapper(
        val type: String,
        @ByteString
        val blob: ByteArray
    ) {
        var typeVersion = LNUrlMetadata.TypeVersion.valueOf(type)
    }

    @Serializable
    @OptIn(ExperimentalSerializationApi::class)
    data class LNUrlSuccessActionWrapper(
        val type: String,
        @ByteString
        val blob: ByteArray
    ) {
        var typeVersion = LNUrlSuccessAction.TypeVersion.valueOf(type)
    }

    @Serializable
    @OptIn(ExperimentalSerializationApi::class)
    data class OriginalFiatWrapper(
        val type: String,
        val rate: Double
    )

    companion object
}

fun WalletPaymentMetadataRow.cloudSerialize(): ByteArray {
    val wrapper = CloudAsset(
        version = CloudAssetVersion.V1.value,
        lnurl_base = lnurl_base?.let {
            CloudAsset.LNUrlBaseWrapper(it.first.name, it.second)
        },
        lnurl_metadata = lnurl_metadata?.let {
            CloudAsset.LNUrlMetadataWrapper(it.first.name, it.second)
        },
        lnurl_successAction = lnurl_successAction?.let {
            CloudAsset.LNUrlSuccessActionWrapper(it.first.name, it.second)
        },
        lnurl_description = lnurl_description,
        user_description = user_description,
        user_notes = user_notes,
        original_fiat = original_fiat?.let {
            CloudAsset.OriginalFiatWrapper(it.first, it.second)
        }
    )
    return Cbor.encodeToByteArray(wrapper)
}

@OptIn(ExperimentalSerializationApi::class)
fun CloudAsset.Companion.cloudDeserialize(blob: ByteArray): WalletPaymentMetadataRow? {
    val wrapper: CloudAsset = try {
        Cbor {
            ignoreUnknownKeys = true
        }.decodeFromByteArray(blob)
    } catch (e: Throwable) {
        return null
    }

    return WalletPaymentMetadataRow(
        lnurl_base = wrapper.lnurl_base?.let {
            Pair(it.typeVersion, it.blob)
        },
        lnurl_metadata = wrapper.lnurl_metadata?.let {
            Pair(it.typeVersion, it.blob)
        },
        lnurl_successAction = wrapper.lnurl_successAction?.let {
            Pair(it.typeVersion, it.blob)
        },
        lnurl_description = wrapper.lnurl_description,
        user_description = wrapper.user_description,
        user_notes = wrapper.user_notes,
        original_fiat = wrapper.original_fiat?.let {
            Pair(it.type, it.rate)
        },
        modified_at = currentTimestampMillis()
    )
}

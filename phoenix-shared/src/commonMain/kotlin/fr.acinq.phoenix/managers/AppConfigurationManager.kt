package fr.acinq.phoenix.managers

import fr.acinq.lightning.blockchain.electrum.ElectrumClient
import fr.acinq.lightning.blockchain.electrum.HeaderSubscriptionResponse
import fr.acinq.lightning.io.TcpSocket
import fr.acinq.lightning.utils.ServerAddress
import fr.acinq.lightning.utils.currentTimestampMillis
import fr.acinq.phoenix.PhoenixBusiness
import fr.acinq.phoenix.data.*
import fr.acinq.phoenix.db.SqliteAppDb
import io.ktor.client.*
import io.ktor.client.request.*
import io.ktor.utils.io.charsets.*
import io.ktor.utils.io.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.datetime.Clock
import org.kodein.log.LoggerFactory
import org.kodein.log.newLogger
import kotlin.math.*
import kotlin.time.*

@OptIn(ExperimentalCoroutinesApi::class, ExperimentalTime::class, ExperimentalStdlibApi::class)
class AppConfigurationManager(
    private val appDb: SqliteAppDb,
    private val httpClient: HttpClient,
    private val electrumClient: ElectrumClient,
    private val chain: Chain,
    loggerFactory: LoggerFactory
) : CoroutineScope by MainScope() {

    constructor(business: PhoenixBusiness) : this(
        loggerFactory = business.loggerFactory,
        chain = business.chain,
        appDb = business.appDb,
        httpClient = business.httpClient,
        electrumClient = business.electrumClient
    )

    private val logger = newLogger(loggerFactory)

    init {
        initWalletContext()
        watchElectrumMessages()
    }

    // Called from AppConnectionsDaemon
    internal fun enableNetworkAccess() {
        startWalletContextLoop()
    }

    // Called from AppConnectionsDaemon
    internal fun disableNetworkAccess() {
        stopWalletContextLoop()
    }

    private val currentWalletContextVersion = WalletContext.Version.V0

    private val _walletContextInitialized = MutableStateFlow<Boolean>(false)

    private val _chainContext = MutableStateFlow<WalletContext.V0.ChainContext?>(null)
    val chainContext: StateFlow<WalletContext.V0.ChainContext?> = _chainContext

    private fun initWalletContext() = launch {
        val (timestamp, localContext) = appDb.getWalletContextOrNull(currentWalletContextVersion)

        val freshness = Duration.milliseconds(Clock.System.now().toEpochMilliseconds() - timestamp)
        logger.info { "local context was updated $freshness ago" }

        val timeout = if (freshness < Duration.hours(48)) {
            Duration.seconds(2)
        } else {
            Duration.seconds(2) * max(freshness.inWholeDays.toInt(), 5)
        } // max=10s

        // TODO are we using TOR? -> increase timeout

        val walletContext = try {
            withTimeout(timeout) {
                fetchAndStoreWalletContext() ?: localContext
            }
        } catch (t: TimeoutCancellationException) {
            logger.warning { "unable to refresh context from remote, using local fallback" }
            localContext
        }

        _chainContext.value = walletContext?.export(chain)
        logger.info { "chainContext=$chainContext" }

        _walletContextInitialized.value = true
    }

    private var updateWalletContextJob: Job? = null
    private fun startWalletContextLoop() {
        launch {
            // suspend until `initWalletContext()` is complete
            _walletContextInitialized.filter { it == true }.first()
            updateWalletContextJob = updateWalletContextLoop()
        }
    }

    private fun stopWalletContextLoop() {
        launch {
            // suspend until `initWalletContext()` is complete
            _walletContextInitialized.filter { it == true }.first()
            updateWalletContextJob?.cancelAndJoin()
        }
    }

    @OptIn(ExperimentalTime::class)
    private fun updateWalletContextLoop() = launch {
        var pause = Duration.seconds(0.5)
        while (isActive) {
            pause = (pause * 2).coerceAtMost(Duration.minutes(5))
            fetchAndStoreWalletContext()?.let {
                val chainContext = it.export(chain)
                _chainContext.value = chainContext
                pause = Duration.minutes(60)
            }
            delay(pause)
        }
    }

    private suspend fun fetchAndStoreWalletContext(): WalletContext.V0? {
        return try {
            httpClient.get<String>("https://acinq.co/phoenix/walletcontext.json")
        } catch (e1: Exception) {
            try {
                httpClient.get<String>("https://s3.eu-west-1.amazonaws.com/acinq.co/phoenix/walletcontext.json")
            } catch (e2: Exception) {
                logger.error { "failed to fetch wallet context: ${e2.message?.take(200)}" }
                null
            }
        }?.let {
            appDb.setWalletContext(currentWalletContextVersion, it)
        }
    }

    private val publicSuffixListKey = "publicSuffixList"
    private val publicSuffixListDefaultRefresh = Duration.days(30)

    private suspend fun fetchPublicSuffixList(
        refreshIfOlderThan: Duration = publicSuffixListDefaultRefresh
    ): Pair<String, Long>? {
        val databaseRow = appDb.getValue(publicSuffixListKey) {
            String(bytes = it, charset = Charsets.UTF_8)
        }
        if (databaseRow != null) {
            val elapsed = currentTimestampMillis() - databaseRow.second
            if (Duration.milliseconds(elapsed) <= refreshIfOlderThan) {
                return databaseRow
            }
        }

        val latestList: String = try {
            httpClient.get("https://acinq.co/phoenix/public_suffix_list.dat")
        } catch (err: Throwable) {
            logger.warning { "Error fetching public_suffix_list.dat: $err" }
            return databaseRow
        }

        val latestListData = latestList.toByteArray(charset = Charsets.UTF_8)
        val refreshTimestamp = appDb.setValue(latestListData, publicSuffixListKey)
        return Pair(latestList, refreshTimestamp)
    }

    suspend fun fetchPublicSuffixListAsync(
        refreshIfOlderThan: Duration = publicSuffixListDefaultRefresh
    ): Deferred<Pair<String, Long>?> {
        return async {
            fetchPublicSuffixList(refreshIfOlderThan)
        }
    }

    /**
     * Used by the [PeerManager] to know what parameters to use when starting
     * up the [Peer] connection. If null, the [PeerManager] will wait before
     * instantiating the [Peer].
     */
    private val _startupParams by lazy { MutableStateFlow<StartupParams?>(null) }
    val startupParams: StateFlow<StartupParams?> by lazy { _startupParams }
    internal fun setStartupParams(params: StartupParams) {
        if (_startupParams.value == null) _startupParams.value = params
    }

    /**
     * Used by the [AppConnectionsDaemon] to know which server to connect to.
     * If null, the daemon will wait for a config to be set.
     */
    private val _electrumConfig by lazy { MutableStateFlow<ElectrumConfig?>(null) }
    val electrumConfig: StateFlow<ElectrumConfig?> by lazy { _electrumConfig }

    /**
     * Use this method to set a server to connect to.
     * If null, will connect to a random server from the hard-coded list.
     */
    fun updateElectrumConfig(server: ServerAddress?) {
        _electrumConfig.value = server?.let { ElectrumConfig.Custom(it) } ?: ElectrumConfig.Random
    }

    fun randomElectrumServer() = when (chain) {
        Chain.Mainnet -> electrumMainnetConfigurations.random()
        Chain.Testnet -> electrumTestnetConfigurations.random()
        Chain.Regtest -> platformElectrumRegtestConf()
    }.let {
        if (it.pinnedPublicKey != null) {
            ServerAddress(it.host, it.tlsPort, TcpSocket.TLS.PINNED_PUBLIC_KEY(it.pinnedPublicKey))
        }  else {
            ServerAddress(it.host, it.tlsPort, TcpSocket.TLS.TRUSTED_CERTIFICATES)
        }
    }

    /** The flow containing the electrum header responses messages. */
    private val _electrumMessages by lazy { MutableStateFlow<HeaderSubscriptionResponse?>(null) }
    fun electrumMessages(): StateFlow<HeaderSubscriptionResponse?> = _electrumMessages

    private fun watchElectrumMessages() = launch {
        electrumClient.openNotificationsSubscription().consumeAsFlow().filterIsInstance<HeaderSubscriptionResponse>()
            .collect {
                _electrumMessages.value = it
            }
    }

    // Tor configuration
    private val isTorEnabled = MutableStateFlow(false)
    fun subscribeToIsTorEnabled(): StateFlow<Boolean> = isTorEnabled
    fun updateTorUsage(enabled: Boolean): Unit {
        isTorEnabled.value = enabled
    }

    // Fiat preferences
    data class PreferredFiatCurrencies(
        val primary: FiatCurrency,
        val others: Set<FiatCurrency>
    ) {
        constructor(primary: FiatCurrency, others: List<FiatCurrency>):
            this(primary = primary, others = others.toSet())

        val all: Set<FiatCurrency> get() {
            return if (others.contains(primary)) {
                others
            } else {
                others.toMutableSet().apply { add(primary) }
            }
        }
    }

    private val _preferredFiatCurrencies by lazy { MutableStateFlow<PreferredFiatCurrencies?>(null) }
    val preferredFiatCurrencies: StateFlow<PreferredFiatCurrencies?> by lazy { _preferredFiatCurrencies }

    fun updatePreferredFiatCurrencies(current: PreferredFiatCurrencies) {
        _preferredFiatCurrencies.value = current
    }
}

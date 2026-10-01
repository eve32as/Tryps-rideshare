package com.tryps.app

import android.app.Application
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.functions.FirebaseFunctions
import com.tryps.data.DemoAccountRepository
import com.tryps.data.DemoRideRepository
import com.tryps.data.FirebaseAccountRepository
import com.tryps.data.FirebaseRideRepository
import com.tryps.domain.AccountRepository
import com.tryps.domain.RideRepository

class TrypsApplication : Application() {
    lateinit var accountRepository: AccountRepository
        private set
    lateinit var rideRepository: RideRepository
        private set
    var isDemoMode: Boolean = true
        private set

    override fun onCreate() {
        super.onCreate()
        val configured = listOf(BuildConfig.FIREBASE_API_KEY, BuildConfig.FIREBASE_APP_ID, BuildConfig.FIREBASE_PROJECT_ID)
            .all(String::isNotBlank)
        if (configured) {
            val options = FirebaseOptions.Builder()
                .setApiKey(BuildConfig.FIREBASE_API_KEY)
                .setApplicationId(BuildConfig.FIREBASE_APP_ID)
                .setProjectId(BuildConfig.FIREBASE_PROJECT_ID)
                .build()
            if (FirebaseApp.getApps(this).isEmpty()) FirebaseApp.initializeApp(this, options)
            accountRepository = FirebaseAccountRepository(FirebaseAuth.getInstance(), FirebaseFirestore.getInstance())
            rideRepository = FirebaseRideRepository(FirebaseFirestore.getInstance(), FirebaseFunctions.getInstance())
            isDemoMode = false
        } else {
            accountRepository = DemoAccountRepository()
            rideRepository = DemoRideRepository()
        }
    }
}

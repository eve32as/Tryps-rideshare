#if canImport(SwiftUI)
import SwiftUI
#if canImport(FirebaseAuth) && canImport(FirebaseCore)
@preconcurrency import FirebaseAuth
import FirebaseCore
#endif

@MainActor
final class FirebaseAccountStore: ObservableObject {
    static let shared = FirebaseAccountStore()

    @Published private(set) var email: String?
    @Published private(set) var isConfigured = false
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    #if canImport(FirebaseAuth) && canImport(FirebaseCore)
    private var authListener: AuthStateDidChangeListenerHandle?
    #endif

    private init() {
        #if canImport(FirebaseAuth) && canImport(FirebaseCore)
        isConfigured = FirebaseApp.app() != nil
        if isConfigured {
            authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
                let currentEmail = user?.email
                Task { @MainActor in
                    self?.email = currentEmail
                }
            }
        }
        #endif
    }

    func signIn(email: String, password: String) {
        authenticate(email: email, password: password, createAccount: false)
    }

    func createAccount(email: String, password: String) {
        authenticate(email: email, password: password, createAccount: true)
    }

    func signOut() {
        #if canImport(FirebaseAuth) && canImport(FirebaseCore)
        do {
            try Auth.auth().signOut()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t sign out. Please try again."
        }
        #else
        errorMessage = "Firebase Auth is available in the Xcode app after setup."
        #endif
    }

    private func authenticate(email: String, password: String, createAccount: Bool) {
        guard isConfigured else {
            errorMessage = "Add GoogleService-Info.plist from your Firebase project to enable accounts."
            return
        }
        guard email.contains("@"), password.count >= 6 else {
            errorMessage = "Enter a valid email and a password with at least 6 characters."
            return
        }

        #if canImport(FirebaseAuth) && canImport(FirebaseCore)
        isWorking = true
        errorMessage = nil
        let completion: (AuthDataResult?, Error?) -> Void = { [weak self] _, error in
            let didFail = error != nil
            Task { @MainActor in
                self?.isWorking = false
                if didFail {
                    self?.errorMessage = createAccount
                        ? "Couldn’t create your account. Check your details and try again."
                        : "Couldn’t sign in. Check your email and password."
                }
            }
        }
        if createAccount {
            Auth.auth().createUser(withEmail: email, password: password, completion: completion)
        } else {
            Auth.auth().signIn(withEmail: email, password: password, completion: completion)
        }
        #endif
    }
}

struct FirebaseAccountView: View {
    @ObservedObject var account: FirebaseAccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isCreatingAccount = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                if let signedInEmail = account.email {
                    Label("Signed in", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(TrypsStyle.green)
                    Text(signedInEmail)
                        .font(.body)
                        .foregroundStyle(TrypsStyle.ink)
                    Button("Sign out", role: .destructive) {
                        account.signOut()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text(isCreatingAccount ? "Create your account" : "Welcome back")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(TrypsStyle.ink)

                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
#if os(iOS)
                        .keyboardType(.emailAddress)
#endif
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password (at least 6 characters)", text: $password)
                        .textContentType(isCreatingAccount ? .newPassword : .password)
                        .textFieldStyle(.roundedBorder)

                    if let errorMessage = account.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        if isCreatingAccount {
                            account.createAccount(email: email, password: password)
                        } else {
                            account.signIn(email: email, password: password)
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if account.isWorking {
                                ProgressView().tint(.white)
                            } else {
                                Text(isCreatingAccount ? "Create account" : "Sign in")
                                    .fontWeight(.bold)
                            }
                            Spacer()
                        }
                        .frame(height: 52)
                        .foregroundStyle(.white)
                        .background(TrypsStyle.green, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .disabled(account.isWorking)

                    Button(isCreatingAccount ? "Already have an account? Sign in" : "New to Tryps? Create an account") {
                        isCreatingAccount.toggle()
                        account.errorMessage = nil
                    }
                    .font(.footnote.weight(.semibold))
                    .tint(TrypsStyle.green)
                    .frame(maxWidth: .infinity)

                    if !account.isConfigured {
                        Text("Firebase isn’t configured yet. Follow the Firebase setup steps in the project README.")
                            .font(.footnote)
                            .foregroundStyle(TrypsStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Your account")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(TrypsStyle.green)
                }
            }
        }
    }
}
#endif

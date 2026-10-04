import SwiftUI

struct LoginScreen: View {
    @EnvironmentObject var state: AppState
    @State private var email = ""
    @State private var password = ""
    @State private var confirmationCode = ""
    @State private var isLoading = false
    @State private var showCodeStep = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Sign in with Firefox")
                .font(.title)
                .bold()
            Text("Use your Mozilla account to activate the VPN.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Firefox account email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            SecureField("Password", text: $password)
                .textContentType(.password)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            if showCodeStep {
                Text("Enter the confirmation code sent to your email")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("Confirmation code", text: $confirmationCode)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }

            Button(action: submit) {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    Text(showCodeStep ? "Verify" : "Continue")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || email.isEmpty)

            Spacer()
        }
        .padding(24)
    }

    private func submit() {
        isLoading = true
        errorMessage = nil
        Task {
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                isLoading = false
                if showCodeStep {
                    state.email = email
                } else {
                    showCodeStep = true
                }
            }
        }
    }
}

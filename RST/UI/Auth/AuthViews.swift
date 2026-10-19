import SwiftUI

/// Вход, регистрация и восстановление по ключу.
struct AuthFlowView: View {
    enum Mode { case login, register, recovery }

    @Environment(AppModel.self) private var app
    @State private var mode: Mode = .login

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                    .padding(.top, 48)
                if !app.savedAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(app.addingAccount ? "Или вернитесь в аккаунт" : "Аккаунты на этом устройстве")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                        ForEach(app.savedAccounts, id: \.username) { account in
                            Button { app.switchAccount(account.username) } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle.fill").font(.system(size: 22))
                                    Text("@" + account.username).font(.system(size: 16, weight: .medium))
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                                }
                                .padding(12)
                                .background(Theme.input, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                switch mode {
                case .login: LoginForm(mode: $mode)
                case .register: RegisterForm(mode: $mode)
                case .recovery: RecoveryForm(mode: $mode)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(colors: [Theme.accentLight, Color(hex: 0xFF7043)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 76, height: 76)
                Image(systemName: "ellipsis.bubble.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("RST")
                .font(.system(size: 30, weight: .heavy))
                .tracking(4)
                .foregroundStyle(Theme.onSurface)
            Text("Сообщения со сквозным шифрованием")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
            if let reason = app.sessionEndMessage {
                Text(reason)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.onSurface)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 8)
            }
        }
    }
}

private struct ErrorLine: View {
    let text: String?
    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LoginForm: View {
    @Binding var mode: AuthFlowView.Mode
    @Environment(AppModel.self) private var app
    @State private var login = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showQr = false

    var body: some View {
        VStack(spacing: 14) {
            TextField("Имя пользователя или почта", text: $login)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(RstTextFieldStyle())
            SecureField("Пароль", text: $password)
                .textContentType(.password)
                .textFieldStyle(RstTextFieldStyle())
                .onSubmit(submit)
            ErrorLine(text: error)
            Button(action: submit) {
                if busy { ProgressView().tint(.white) } else { Text("Войти") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || login.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)

            Button { showQr = true } label: {
                Label("Войти по QR-коду", systemImage: "qrcode")
            }
            .font(.system(size: 15, weight: .medium))
            .padding(.top, 4)
            Button("Забыли пароль? Войти по ключу восстановления") { mode = .recovery }
                .font(.system(size: 14))
            HStack(spacing: 4) {
                Text("Нет аккаунта?").foregroundStyle(Theme.muted)
                Button("Зарегистрироваться") { mode = .register }
            }
            .font(.system(size: 15))
            .padding(.top, 8)
        }
        .sheet(isPresented: $showQr) { QrLoginSheet() }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await app.services.auth.login(login.trimmingCharacters(in: .whitespaces), password: password)
                password = ""
                app.enterApp()
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

private struct RegisterForm: View {
    @Binding var mode: AuthFlowView.Mode
    @Environment(AppModel.self) private var app
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var busy = false
    @State private var error: String?

    private var validationError: String? {
        let name = username.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name.range(of: "^[a-zA-Z0-9_-]{3,32}$", options: .regularExpression) == nil {
            return "Имя: 3–32 знака, латиница, цифры, «_» и «-»"
        }
        if !password.isEmpty && password.count < 8 { return "Пароль — не короче 8 символов" }
        if password.utf8.count > 72 { return "Пароль слишком длинный (больше 72 байт)" }
        if !repeatPassword.isEmpty && repeatPassword != password { return "Пароли не совпадают" }
        return nil
    }

    var body: some View {
        VStack(spacing: 14) {
            TextField("Имя пользователя (латиница)", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(RstTextFieldStyle())
            TextField("Почта", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(RstTextFieldStyle())
            SecureField("Пароль (от 8 символов)", text: $password)
                .textContentType(.newPassword)
                .textFieldStyle(RstTextFieldStyle())
            SecureField("Пароль ещё раз", text: $repeatPassword)
                .textContentType(.newPassword)
                .textFieldStyle(RstTextFieldStyle())
            Text("Пароль — это и ключ к вашей переписке: сервер его не знает и восстановить не сможет. После входа создайте ключ восстановления в настройках.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ErrorLine(text: error ?? validationError)
            Button(action: submit) {
                if busy { ProgressView().tint(.white) } else { Text("Создать аккаунт") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || validationError != nil || username.isEmpty || email.isEmpty || password.isEmpty || repeatPassword != password)
            HStack(spacing: 4) {
                Text("Уже есть аккаунт?").foregroundStyle(Theme.muted)
                Button("Войти") { mode = .login }
            }
            .font(.system(size: 15))
            .padding(.top, 8)
        }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await app.services.auth.register(
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password,
                    email: email.trimmingCharacters(in: .whitespaces))
                app.enterApp()
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

private struct RecoveryForm: View {
    @Binding var mode: AuthFlowView.Mode
    @Environment(AppModel.self) private var app
    @State private var login = ""
    @State private var code = ""
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Text("Ключ восстановления позволяет задать новый пароль и сохранить всю переписку.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Имя пользователя или почта", text: $login)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(RstTextFieldStyle())
            TextField("Ключ: ABCD-EFGH-…", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(RstTextFieldStyle())
            SecureField("Новый пароль", text: $password)
                .textContentType(.newPassword)
                .textFieldStyle(RstTextFieldStyle())
            SecureField("Новый пароль ещё раз", text: $repeatPassword)
                .textContentType(.newPassword)
                .textFieldStyle(RstTextFieldStyle())
            ErrorLine(text: error ?? (repeatPassword.isEmpty || repeatPassword == password ? nil : "Пароли не совпадают"))
            Button(action: submit) {
                if busy { ProgressView().tint(.white) } else { Text("Задать новый пароль") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || login.isEmpty || code.isEmpty || password.count < 8 || password != repeatPassword)
            Button("Вернуться ко входу") { mode = .login }
                .font(.system(size: 15))
                .padding(.top, 8)
        }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await app.services.auth.resetPassword(
                    login: login.trimmingCharacters(in: .whitespaces), code: code, newPassword: password)
                app.enterApp()
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

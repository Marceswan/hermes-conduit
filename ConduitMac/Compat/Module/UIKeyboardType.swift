/// Macs have no on-screen keyboard; the cases only let call sites compile.
public enum UIKeyboardType: Int, Sendable {
    case `default`, numbersAndPunctuation, URL, numberPad, decimalPad, asciiCapable
}

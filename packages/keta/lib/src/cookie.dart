library;

/// A `Set-Cookie` attribute value: whether (and how strictly) the cookie is
/// withheld on cross-site requests (RFC 6265bis §5.2).
enum SameSite {
  /// Sent on same-site requests and top-level cross-site navigations.
  lax,

  /// Sent on same-site requests only.
  strict,

  /// Sent on all requests, including cross-site. Requires [SetCookie.secure]
  /// (RFC 6265bis) — enforced at construction.
  none,
}

/// A typed `Set-Cookie` value, rendered by [toHeaderValue].
///
/// It rides the ordinary multi-value response headers — there is no second
/// channel: `c.json(v, headers: {'set-cookie': [cookie.toHeaderValue()]})`.
/// Multiple cookies are multiple list entries.
///
/// Name, value, and the attribute strings are validated at construction against
/// the RFC 6265 token / cookie-octet rules, so a constructed [SetCookie] cannot
/// carry a `;`, CR, LF, or other control character into a header — header
/// injection is made unrepresentable, the same guarantee [Response] gives its
/// header map.
final class SetCookie {
  /// Constructs and validates a cookie. Throws [ArgumentError] when [name] is
  /// not an RFC 6265 token, [value] is not a cookie-value, [domain] or [path]
  /// carry a control character or `;`, or [sameSite] is [SameSite.none] without
  /// [secure] (RFC 6265bis requires `Secure` for `SameSite=None`).
  SetCookie(
    this.name,
    this.value, {
    this.maxAge,
    this.expires,
    this.domain,
    this.path,
    this.secure = false,
    this.httpOnly = false,
    this.sameSite,
  }) {
    _checkName(name);
    _checkValue(value);
    if (domain != null) _checkAttr(domain!, 'domain');
    if (path != null) _checkAttr(path!, 'path');
    // RFC 6265bis: a cookie is rejected by the browser if SameSite=None is set
    // without Secure. Reject it here rather than emit a cookie no browser keeps.
    if (sameSite == SameSite.none && !secure) {
      throw ArgumentError.value(
        sameSite,
        'sameSite',
        'SameSite=None requires secure: true (RFC 6265bis)',
      );
    }
  }

  final String name;
  final String value;

  /// `Max-Age` in seconds. Independent of [expires]; both may be set.
  final Duration? maxAge;

  /// `Expires`, emitted as an IMF-fixdate in UTC (RFC 9110 §5.6.7).
  final DateTime? expires;

  final String? domain;
  final String? path;
  final bool secure;
  final bool httpOnly;
  final SameSite? sameSite;

  /// Renders the `Set-Cookie` field value: `name=value` followed by each set
  /// attribute in RFC 6265 §4.1.1 order.
  String toHeaderValue() {
    final b = StringBuffer('$name=$value');
    if (maxAge != null) b.write('; Max-Age=${maxAge!.inSeconds}');
    if (expires != null) b.write('; Expires=${_imfFixdate(expires!)}');
    if (domain != null) b.write('; Domain=$domain');
    if (path != null) b.write('; Path=$path');
    if (secure) b.write('; Secure');
    if (httpOnly) b.write('; HttpOnly');
    if (sameSite != null) b.write('; SameSite=${_sameSiteToken(sameSite!)}');
    return b.toString();
  }

  static String _sameSiteToken(SameSite s) => switch (s) {
    SameSite.lax => 'Lax',
    SameSite.strict => 'Strict',
    SameSite.none => 'None',
  };

  static void _checkName(String name) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'cookie name must not be empty');
    }
    for (final u in name.codeUnits) {
      // RFC 6265 cookie-name is an RFC 9110 token: VCHAR minus separators.
      if (u <= 0x20 || u >= 0x7f || _isSeparator(u)) {
        throw ArgumentError.value(
          name,
          'name',
          'cookie name must be an RFC 6265 token',
        );
      }
    }
  }

  static void _checkValue(String value) {
    var s = value;
    // A cookie-value may be wrapped in a single pair of DQUOTEs (RFC 6265
    // §4.1.1); the octets inside are still constrained to cookie-octet.
    if (s.length >= 2 &&
        s.codeUnitAt(0) == 0x22 &&
        s.codeUnitAt(s.length - 1) == 0x22) {
      s = s.substring(1, s.length - 1);
    }
    for (final u in s.codeUnits) {
      if (!_isCookieOctet(u)) {
        throw ArgumentError.value(
          value,
          'value',
          'cookie value must be RFC 6265 cookie-octet '
              '(no whitespace, ",", ";", "\\", DQUOTE, or control characters)',
        );
      }
    }
  }

  static void _checkAttr(String v, String field) {
    for (final u in v.codeUnits) {
      // av-octet: any CHAR except CTLs and ";" (RFC 6265 §4.1.1). The ";" guard
      // is what stops a domain/path from opening a second attribute.
      if (u < 0x20 || u == 0x7f || u == 0x3b) {
        throw ArgumentError.value(
          v,
          field,
          '$field must not contain control characters or ";"',
        );
      }
    }
  }

  // token separators (RFC 9110 §5.6.2 / RFC 2616): ()<>@,;:\"/[]?={} plus SP/HT.
  static bool _isSeparator(int u) => switch (u) {
    0x28 || 0x29 || 0x3c || 0x3e || 0x40 => true, // ( ) < > @
    0x2c || 0x3b || 0x3a || 0x5c || 0x22 => true, // , ; : \ "
    0x2f || 0x5b || 0x5d || 0x3f || 0x3d => true, // / [ ] ? =
    0x7b || 0x7d => true, // { }
    _ => false,
  };

  static bool _isCookieOctet(int u) =>
      u == 0x21 || // !
      (u >= 0x23 && u <= 0x2b) || // %x23-2B  (excludes " and ,)
      (u >= 0x2d && u <= 0x3a) || // %x2D-3A  (excludes ,)
      (u >= 0x3c && u <= 0x5b) || // %x3C-5B  (excludes ;)
      (u >= 0x5d && u <= 0x7e); // %x5D-7E  (excludes \)

  static String _imfFixdate(DateTime dt) {
    final u = dt.toUtc();
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${days[u.weekday - 1]}, ${p2(u.day)} ${months[u.month - 1]} '
        '${u.year} ${p2(u.hour)}:${p2(u.minute)}:${p2(u.second)} GMT';
  }
}

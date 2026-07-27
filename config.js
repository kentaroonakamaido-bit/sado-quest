// 佐渡クエスト 接続設定
// この2つの値は「公開してよい値」です（ブラウザに読ませる前提の鍵）。
// 本当の秘密鍵（sb_secret_ で始まるもの）は絶対にここに書かないでください。
//
// 【重要】家族に配る共有URLの合言葉（share_token）は、ここには書きません。
// 合言葉はURLの「?t=...」の部分だけに入っています。
// このファイルは公開リポジトリに置かれるため、合言葉を書くと意味がなくなります。
window.SADO_CONFIG = {
  SUPABASE_URL: 'https://ewpqucrsvgicqlmbotvo.supabase.co',
  SUPABASE_KEY: 'sb_publishable_GN2YwmobTQt6dpeccWFLLw__4X-biBJ'
};

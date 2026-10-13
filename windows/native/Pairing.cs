using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

public static class Pairing {
    public sealed class Address { public string IP;public int Port,Channel;public byte[] Secret; }
    public static Address Parse(string code) {
        code=(code??"").Trim();if(!code.StartsWith("MS1-",StringComparison.Ordinal) || code.Length!=35)throw new ArgumentException("Paste the complete pairing code copied from the Mac.");
        byte[] raw=Convert.FromBase64String(code.Substring(4).Replace('-','+').Replace('_','/')+"=");
        if(raw.Length!=23 || raw[6]<1 || raw[6]>3)throw new ArgumentException("Invalid pairing code.");
        int port=raw[4]*256+raw[5];if(port==0)throw new ArgumentException("Invalid pairing port.");
        byte[] secret=new byte[16];Buffer.BlockCopy(raw,7,secret,0,16);
        return new Address {IP=new IPAddress(new byte[]{raw[0],raw[1],raw[2],raw[3]}).ToString(),Port=port,Channel=raw[6],Secret=secret};
    }
    static byte[] Digest(byte[] key,string text) {using(var h=new HMACSHA256(key))return h.ComputeHash(Encoding.UTF8.GetBytes(text));}
    static string Hex(byte[] bytes) {return BitConverter.ToString(bytes).Replace("-","").ToLowerInvariant();}
    public static Profile Decode(string json,Address address,string nonce) {
        if(json.Length>16384)throw new ArgumentException("Pairing response is too large.");
        var value=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(json);
        if(value==null || value.Count!=5 || !value.ContainsKey("v") || !value.ContainsKey("nonce") || !value.ContainsKey("iv") || !value.ContainsKey("ciphertext") || !value.ContainsKey("mac") || !(value["v"] is int) || (int)value["v"]!=1 || (string)value["nonce"]!=nonce)throw new ArgumentException("Invalid pairing response.");
        string iv=(string)value["iv"],cipher=(string)value["ciphertext"],mac=(string)value["mac"];
        string expected=Hex(Digest(Digest(address.Secret,"MonitorSwitch pairing authentication v1"),"response|1|"+nonce+"|"+iv+"|"+cipher));
        if(mac==null || mac.Length!=64)throw new ArgumentException("Invalid pairing authentication.");
        int difference=0;for(int i=0;i<64;i++)difference|=mac[i]^expected[i];
        if(difference!=0)throw new ArgumentException("Pairing authentication failed. Generate a fresh code on the Mac.");
        byte[] clear,ivBytes=Convert.FromBase64String(iv),encrypted=Convert.FromBase64String(cipher);
        if(ivBytes.Length!=16 || encrypted.Length>8192 || encrypted.Length==0 || encrypted.Length%16!=0)throw new ArgumentException("Invalid encrypted profile.");
        using(var aes=Aes.Create()) {
            aes.Key=Digest(address.Secret,"MonitorSwitch pairing encryption v1");aes.IV=ivBytes;aes.Mode=CipherMode.CBC;aes.Padding=PaddingMode.PKCS7;
            using(var decrypt=aes.CreateDecryptor())clear=decrypt.TransformFinalBlock(encrypted,0,encrypted.Length);
        }
        try {
            var profile=new JavaScriptSerializer().Deserialize<Profile>(Encoding.UTF8.GetString(clear));if(profile==null)throw new ArgumentException("Empty paired profile.");profile.Validate();
            if(profile.channel!=address.Channel || profile.macIP!=address.IP)throw new ArgumentException("The returned profile does not match the pairing code.");
            return profile;
        } finally {Array.Clear(clear,0,clear.Length);}
    }
    public static void SelfTest(string path) {
        var fixture=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(path));
        Address address=Parse((string)fixture["code"]);string nonce=(string)fixture["nonce"];
        string json=new JavaScriptSerializer().Serialize(fixture["response"]);Profile profile=Decode(json,address,nonce);
        if(profile.channel!=2 || profile.macChannel!=3 || profile.inputs[1]!=18)throw new Exception("Cross-platform pairing profile failed");
        address.Secret[0]^=1;bool rejected=false;
        try {Decode(json,address,nonce);}catch(ArgumentException){rejected=true;}
        if(!rejected)throw new Exception("Wrong pairing secret accepted");
        address.Secret[0]^=1;rejected=false;
        try {Decode(json,address,new string('b',32));}catch(ArgumentException){rejected=true;}
        if(!rejected)throw new Exception("Wrong pairing nonce accepted");
        Array.Clear(address.Secret,0,address.Secret.Length);
    }
    public static Profile Connect(string code) {
        Address address=Parse(code);string nonce=Guid.NewGuid().ToString("N");
        try {
            string json=new JavaScriptSerializer().Serialize(new Dictionary<string,object>{{"v",1},{"nonce",nonce},{"mac",Hex(Digest(address.Secret,"request|1|"+nonce))}});
            var request=(HttpWebRequest)WebRequest.Create("http://"+address.IP+":"+address.Port+"/pair");
            request.Method="POST";request.Proxy=null;request.AllowAutoRedirect=false;request.Timeout=5000;request.ReadWriteTimeout=5000;request.ContentType="application/json";
            byte[] bytes=Encoding.UTF8.GetBytes(json);request.ContentLength=bytes.Length;
            using(var stream=request.GetRequestStream())stream.Write(bytes,0,bytes.Length);
            using(var response=request.GetResponse())using(var stream=response.GetResponseStream())using(var output=new MemoryStream()) {
                byte[] buffer=new byte[1024];int count;
                while((count=stream.Read(buffer,0,buffer.Length))>0){if(output.Length+count>16384)throw new ArgumentException("Pairing response is too large.");output.Write(buffer,0,count);}
                return Decode(Encoding.UTF8.GetString(output.ToArray()),address,nonce);
            }
        } catch(WebException) {throw new ArgumentException("Pairing failed or the code expired. Keep both devices on the same network and copy a fresh code from the Mac.");}
        finally {Array.Clear(address.Secret,0,address.Secret.Length);}
    }
}

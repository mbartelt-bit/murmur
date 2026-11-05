import type { CapacitorConfig } from '@capacitor/cli';
const config: CapacitorConfig = {
  appId: 'com.murmur.mobile', appName: 'Murmur', webDir: 'dist',
  ios: { contentInset: 'never', backgroundColor: '#f5f4ef' },
  android: { backgroundColor: '#f5f4ef' },
};
export default config;
